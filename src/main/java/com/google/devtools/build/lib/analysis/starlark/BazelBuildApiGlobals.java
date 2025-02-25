// Copyright 2018 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package com.google.devtools.build.lib.analysis.starlark;

import com.google.common.collect.ImmutableList;
import com.google.devtools.build.lib.cmdline.LabelSyntaxException;
import com.google.devtools.build.lib.cmdline.PackageIdentifier;
import com.google.devtools.build.lib.cmdline.RepositoryName;
import com.google.devtools.build.lib.packages.BazelStarlarkContext;
import com.google.devtools.build.lib.packages.BzlInitThreadContext;
import com.google.devtools.build.lib.packages.BzlVisibility;
import com.google.devtools.build.lib.packages.PackageSpecification;
import com.google.devtools.build.lib.packages.semantics.BuildLanguageOptions;
import com.google.devtools.build.lib.starlarkbuildapi.StarlarkBuildApiGlobals;
import java.util.List;
import net.starlark.java.eval.EvalException;
import net.starlark.java.eval.Sequence;
import net.starlark.java.eval.Starlark;
import net.starlark.java.eval.StarlarkList;
import net.starlark.java.eval.StarlarkThread;

/**
 * Bazel implementation of {@link StarlarkBuildApiGlobals}: a collection of global Starlark build
 * API functions that belong in the global namespace.
 */
// TODO(brandjon): This should probably be refactored into a StarlarkLibrary#BZL field, analogous to
// StarlarkLibrary#COMMON and StarlarkLibrary#BUILD.
public class BazelBuildApiGlobals implements StarlarkBuildApiGlobals {

  @Override
  public void visibility(Object value, StarlarkThread thread) throws EvalException {
    // Confirm .bzl visibility is enabled. We manually check the experimental flag here because
    // StarlarkMethod.enableOnlyWithFlag doesn't work for top-level builtins.
    if (!thread.getSemantics().getBool(BuildLanguageOptions.EXPERIMENTAL_BZL_VISIBILITY)) {
      throw Starlark.errorf("Use of `visibility()` requires --experimental_bzl_visibility");
    }

    // Fail if we're not initializing a .bzl module
    BzlInitThreadContext context = BzlInitThreadContext.fromOrFailFunction(thread, "visibility");
    // Fail if we're not called from the top level. (We prohibit calling visibility() from within
    // helper functions because it's more magical / less readable, and it makes it more difficult
    // for static tooling to mechanically find and modify visibility() declarations.)
    ImmutableList<StarlarkThread.CallStackEntry> callStack = thread.getCallStack();
    if (!(callStack.size() == 2
        && callStack.get(0).name.equals("<toplevel>")
        && callStack.get(1).name.equals("visibility"))) {
      throw Starlark.errorf(
          ".bzl visibility may only be set at the top level, not inside a function");
    }

    // Fail if the .bzl module isn't on the experimental allowlist.
    PackageIdentifier pkgId = context.getBzlFile().getPackageIdentifier();
    List<String> allowlist =
        thread.getSemantics().get(BuildLanguageOptions.EXPERIMENTAL_BZL_VISIBILITY_ALLOWLIST);
    checkVisibilityAllowlist(pkgId, allowlist);

    // Fail if the module's visibility is already set.
    if (context.getBzlVisibility() != null) {
      throw Starlark.errorf(".bzl visibility may not be set more than once");
    }

    RepositoryName repo = context.getBzlFile().getRepository();
    ImmutableList<PackageSpecification> specs;
    if (value instanceof String) {
      // `visibility("public")`, `visibility("private")`, visibility("//pkg")
      specs =
          ImmutableList.of(PackageSpecification.fromStringForBzlVisibility(repo, (String) value));
    } else if (value instanceof StarlarkList) {
      // `visibility(["//pkg1", "//pkg2", ...])`
      List<String> specStrings = Sequence.cast(value, String.class, "visibility list");
      ImmutableList.Builder<PackageSpecification> specsBuilder =
          ImmutableList.builderWithExpectedSize(specStrings.size());
      for (String specString : specStrings) {
        PackageSpecification spec =
            PackageSpecification.fromStringForBzlVisibility(repo, specString);
        specsBuilder.add(spec);
      }
      specs = specsBuilder.build();
    } else {
      throw Starlark.errorf(
          "Invalid bzl-visibility: got '%s', want string or list of strings", Starlark.type(value));
    }
    context.setBzlVisibility(BzlVisibility.of(specs));
  }

  private void checkVisibilityAllowlist(PackageIdentifier pkgId, List<String> allowlist)
      throws EvalException {
    // The allowlist is represented as a list of strings because BuildLanguageOptions isn't allowed
    // to depend on Label, PackageIdentifier, etc. For simplicity we just convert the strings to
    // PackageIdentifiers here, at linear cost and redundantly for each call to `visibility()`. This
    // is ok because the allowlist is not intended to stay permanent, it is expected to remain
    // small, and calls to visibility() are relatively infrequent.
    boolean foundMatch = false;
    for (String allowedPkgString : allowlist) {
      // Special constant to disable allowlisting. For migration to enable the feature globally.
      if (allowedPkgString.equals("everyone")) {
        foundMatch = true;
        break;
      }
      // The wildcard syntax /... is not valid for PackageIdentifiers, so we extract it first.
      boolean allBeneath = allowedPkgString.endsWith("/...");
      if (allBeneath) {
        allowedPkgString = allowedPkgString.substring(0, allowedPkgString.length() - 4);
        if (allowedPkgString.equals("/")) {
          // was "//..."
          allowedPkgString = "//";
        }
      }
      PackageIdentifier allowedPkgId;
      try {
        // TODO(b/22193153): This seems incorrect since parse doesn't take into account any
        // repository map. (This shouldn't matter within Google's monorepo, which doesn't use a repo
        // map.)
        allowedPkgId = PackageIdentifier.parse(allowedPkgString);
      } catch (LabelSyntaxException ex) {
        throw Starlark.errorf("Invalid bzl-visibility allowlist: %s", ex.getMessage());
      }

      if (pkgId.equals(allowedPkgId)
          || (allBeneath
              // Again, we're erroneously ignoring repo.
              && pkgId.getPackageFragment().startsWith(allowedPkgId.getPackageFragment()))) {
        foundMatch = true;
        break;
      }
    }
    if (!foundMatch) {
      throw Starlark.errorf(
          "`visibility() is not enabled for package %s; consider adding it to "
              + "--experimental_bzl_visibility_allowlist",
          pkgId.getCanonicalForm());
    }
  }

  @Override
  public StarlarkLateBoundDefault<?> configurationField(
      String fragment, String name, StarlarkThread thread) throws EvalException {
    BazelStarlarkContext context = BazelStarlarkContext.from(thread);
    Class<?> fragmentClass = context.getFragmentNameToClass().get(fragment);
    if (fragmentClass == null) {
      throw Starlark.errorf("invalid configuration fragment name '%s'", fragment);
    }
    try {
      return StarlarkLateBoundDefault.forConfigurationField(
          fragmentClass, name, context.getToolsRepository());
    } catch (StarlarkLateBoundDefault.InvalidConfigurationFieldException exception) {
      throw new EvalException(exception);
    }
  }
}
