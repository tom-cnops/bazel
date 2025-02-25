#!/bin/bash
#
# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# --- begin runfiles.bash initialization ---
set -euo pipefail
if [[ ! -d "${RUNFILES_DIR:-/dev/null}" && ! -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles/MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [[ -f "$0.runfiles/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi
if [[ -f "${RUNFILES_DIR:-/dev/null}/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
  source "${RUNFILES_DIR}/bazel_tools/tools/bash/runfiles/runfiles.bash"
elif [[ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  source "$(grep -m1 "^bazel_tools/tools/bash/runfiles/runfiles.bash " \
            "$RUNFILES_MANIFEST_FILE" | cut -d ' ' -f 2-)"
else
  echo >&2 "ERROR: cannot find @bazel_tools//tools/bash/runfiles:runfiles.bash"
  exit 1
fi
# --- end runfiles.bash initialization ---

source "$(rlocation "io_bazel/src/test/shell/integration_test_setup.sh")" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

case "$(uname -s | tr [:upper:] [:lower:])" in
msys*|mingw*|cygwin*)
  declare -r is_windows=true
  ;;
*)
  declare -r is_windows=false
  ;;
esac

if "$is_windows"; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL="*"
  declare -r EXE_EXT=".exe"
else
  declare -r EXE_EXT=""
fi

# Tests in this file do not actually start a Python interpreter, but plug in a
# fake stub executable to serve as the "interpreter".
#
# Note that this means this suite cannot be used for tests of the actual stub
# script under Windows, since the stub script never runs (the launcher uses the
# mock interpreter rather than a system interpreter, see discussion in #7947).

use_fake_python_runtimes_for_testsuite

#### TESTS #############################################################

# Tests that Python 2 or Python 3 is actually invoked.
function test_python_version() {
  mkdir -p test
  touch test/main2.py test/main3.py
  cat > test/BUILD << EOF
py_binary(name = "main2",
    python_version = "PY2",
    srcs = ['main2.py'],
)
py_binary(name = "main3",
    python_version = "PY3",
    srcs = ["main3.py"],
)
EOF

  # Google builds don't support Python 2
  if [[ "$PRODUCT_NAME" == "bazel" ]]; then
    bazel run //test:main2 \
        &> $TEST_log || fail "bazel run failed"
    expect_log "I am Python 2"
  fi

  # Stamping is disabled so that the invocation doesn't time out. What
  # happens is Google has stamping enabled by default, which causes the
  # Starlark rule implementation to run an action, which then tries to run
  # remotely, but network access is disabled by default, so it times out.
  bazel run --nostamp //test:main3 \
      &> $TEST_log || fail "bazel run failed"
  expect_log "I am Python 3"
}

function test_can_build_py_library_at_top_level_regardless_of_version() {
  mkdir -p test
  cat > test/BUILD << EOF
py_library(
    name = "lib2",
    srcs = ["lib2.py"],
    srcs_version = "PY2ONLY",
)
py_library(
    name = "lib3",
    srcs = ["lib3.py"],
    srcs_version = "PY3ONLY",
)
EOF
  touch test/lib2.py test/lib3.py

  bazel build --python_version=PY2 //test:* \
      &> $TEST_log || fail "bazel build failed"
  bazel build --python_version=PY3 //test:* \
      &> $TEST_log || fail "bazel build failed"
}

# Regression test for #7808. We want to ensure that changing the Python version
# to a value different from the top-level configuration, and then changing it
# back again, is able to reuse the top-level configuration.
function test_no_action_conflicts_from_version_transition() {
  # Requires Python 2 support, which doesn't work for Google-internal builds
  if [[ "$PRODUCT_NAME" != "bazel" ]]; then
    return 0
  fi
  mkdir -p test

  # To repro, we need to build a C++ target in two different ways in the same
  # build:
  #
  #   1) At the top-level, and without any explicit flags passed to control the
  #      Python version, because the behavior under test involves the internal
  #      null default value of said flags.
  #
  #   2) As a dependency of a target that transitions the Python version to the
  #      same value as in the top-level configuration.
  #
  # We need to use two different Python targets, to transition the version
  # *away* from the top-level default and then *back* again. Furthermore,
  # because (as of the writing of this test) the default Python version is in
  # the process of being migrated from PY2 to PY3, we'll future-proof this test
  # by using two separate paths that have the versions inverted.
  #
  # We use C++ for the repro because it has unshareable actions, so we'll know
  # if the top-level config isn't being reused.

  cat > test/BUILD << EOF
cc_binary(
    name = "cc",
    srcs = ["cc.cc"],
)

py_binary(
    name = "path_A_inner",
    srcs = ["path_A_inner.py"],
    data = [":cc"],
    python_version = "PY2",
)

py_binary(
    name = "path_A_outer",
    srcs = [":path_A_outer.py"],
    data = [":path_A_inner"],
    python_version = "PY3",
)

py_binary(
    name = "path_B_inner",
    srcs = [":path_B_inner.py"],
    data = [":cc"],
    python_version = "PY3",
)

py_binary(
    name = "path_B_outer",
    srcs = [":path_B_outer.py"],
    data = [":path_B_inner"],
    python_version = "PY2",
)
EOF

  # Build cc at the top level, along with the outer halves of both paths to cc.
  bazel build --nobuild //test:cc //test:path_A_outer //test:path_B_outer \
      &> $TEST_log || fail "bazel run failed"
}

# When invoking a Python binary using the runfiles manifest, the stub
# script's argv[0] will point to a location in the execroot; not the
# runfiles directory of the caller. The stub script should still be
# capable of finding its runfiles directory by considering RUNFILES_DIR
# and RUNFILES_MANIFEST_FILE set by the caller.
function test_python_through_bash_without_runfile_links() {
  mkdir -p python_through_bash

  cat > python_through_bash/BUILD << EOF
py_binary(
    name = "inner",
    srcs = ["inner.py"],
)

sh_binary(
    name = "outer",
    srcs = ["outer.sh"],
    data = [":inner"],
)
EOF

  cat > python_through_bash/outer.sh << EOF
#!/bin/bash
# * Bazel run guarantees that our CWD is the runfiles directory itself, so a
#   relative path will work.
# * We can't use the usual shell runfiles library because it doesn't work in the
#   Google environment nested within a generated shell test.
find . -name inner$EXE_EXT | xargs env
EOF
  chmod +x python_through_bash/outer.sh

  touch python_through_bash/inner.py

  bazel run --nobuild_runfile_links //python_through_bash:outer \
    &> $TEST_log || fail "bazel run failed"
  expect_log "I am Python"
}

run_suite "Tests for the Python rules without Python execution"
