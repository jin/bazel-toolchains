# Copyright 2017 The Bazel Authors. All rights reserved.
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

"""Rules for generating toolchain configs for a Docker container.

Exposes the docker_autoconfigure rule that does the following:
- Receive a base container as main input. Base container could have a desired
  set of toolchains (i.e., a C compiler, C libraries, java, python, zip, and
  other tools) installed.
- Optionally, install more debian packages in the base container (any packages
  that might be needed by Bazel not installed in your container).
- Optionally, install a given Bazel version on the container.
- Extend the container to install sources for a project.
- Run a bazel command to build one or more targets from
  remote repositories, inside the container.
- Copy toolchain configs (outputs of remote repo targets) produced
  from the execution of Bazel inside the container to the host.
- Optionally copy outputs to a folder defined via build variables.

Example:

  docker_toolchain_autoconfig(
      name = "my-autoconfig-rule",
      base = "@my_image//image:image.tar",
      bazel_version = "0.10.0",
      config_repos = ["local_config_cc", "<some_other_skylark_repo>"],
      git_repo = "https://github.com/some_git_repo",
      env = {
          ... Dictionary of env variables to configure Bazel properly
              for the container, see environments.bzl for examples.
      },
      packages = [
          "package_1",
          "package_2=version",
      ],
      # Any additional debian repos and keys needed to install packages above,
      # not needed if no packages are installed.
      additional_repos = [
          "deb http://deb.debian.org/debian jessie-backports main",
      ],
      keys = [
          "@some_gpg//file",
      ],
  )

Add to your WORKSPACE file the following:

  http_archive(
    name = "bazel_toolchains",
    urls = [
      "https://mirror.bazel.build/github.com/bazelbuild/bazel-toolchains/archive/<latest_release>.tar.gz",
      "https://github.com/bazelbuild/bazel-toolchains/archive/<latest_release>.tar.gz",
    ],
    strip_prefix = "bazel-toolchains-<latest_commit>",
    sha256 = "<sha256>",
  )

  http_archive(
      name = "debian_docker",
      sha256 = "<sha256>",
      strip_prefix = "base-images-docker-<latest_release>",
      urls = ["https://github.com/GoogleCloudPlatform/base-images-docker/archive/<latest_release>.tar.gz"],
  )

  http_archive(
      name = "io_bazel_rules_docker",
      sha256 = "<sha256>",
      strip_prefix = "rules_docker-<latest_release>",
      urls = ["https://github.com/bazelbuild/rules_docker/archive/<latest_release>.tar.gz"],
  )

  load(
      "@io_bazel_rules_docker//container:container.bzl",
      container_repositories = "repositories",
      "container_pull",
  )

  container_repositories()

  # Pulls the my_image used as base for example above
  container_pull(
      name = "my_image",
      digest = "sha256:<sha256>",
      registry = "<registry>",
      repository = "<repo>",
  )

  # GPG file used by example above
  http_file(
    name = "some_gpg",
    sha256 = "<sha256>",
    url = "<URL>",
  )

For values of <latest_release> and other placeholders above, please see
the WORKSPACE file in this repo.

To use the rule run:

  bazel run --define=DOCKER_AUTOCONF_OUTPUT=<some_output_dir> //<location_of_rule>:my-autoconfig-rule

Once rule finishes running the file <some_output_dir>/my-autoconfig-rule.tar
will be created with all toolchain configs generated by
"local_config_cc" and "<some_other_skylark_repo>". If no value for
DOCKER_AUTOCONF_OUTPUT is passed, the resulting tar file is left in /tmp.

Known issues:

 - 'name' of rule must conform to docker image naming standards
 - Rule cannot be placed in the BUILD file at the root of a project
"""

load(
    "@io_bazel_rules_docker//container:container.bzl",
    _container = "container",
)
load("@debian_docker//package_managers:download_pkgs.bzl", "download_pkgs")
load("@debian_docker//package_managers:install_pkgs.bzl", "install_pkgs")
load("@debian_docker//package_managers:apt_key.bzl", "add_apt_key")

# External folder is set to be deprecated, lets keep it here for easy
# refactoring
# https://github.com/bazelbuild/bazel/issues/1262
_EXTERNAL_FOLDER_PREFIX = "external/"

# Name of the current workspace
_WORKSPACE_NAME = "bazel_toolchains"

_WORKSPACE_PREFIX = "@" + _WORKSPACE_NAME + "//"

# Default cc project to use if no git_repo is provided.
_DEFAULT_AUTOCONFIG_PROJECT_PKG_TAR = _WORKSPACE_PREFIX + "rules:cc-sample-project-tar"

# Build variable to define the location of the output tar produced by
# docker_toolchain_autoconfig
_DOCKER_AUTOCONF_OUTPUT = "DOCKER_AUTOCONF_OUTPUT"

# Filetype to restrict inputs
tar_filetype = [
    ".tar",
    ".tar.xz",
]

def container_install_pkgs(name, base, packages, additional_repos, keys):
  """Macro to download and install deb packages in a container.

  The output image with packages installed will have name {name}.tar.

  Args:
    name: name of this rule. It is also the name of the output image.
    base: the base layers on top of which to overlay a layer with the
      desired packages.
    packages: list of packages to fetch and install in the base image.
    additional_repos: list of additional debian package repos to use,
      in sources.list format.
    keys: label of additional gpg keys to use while downloading packages.
  """

  # Create an intermediate image which includes additional gpg keys.
  add_apt_key(
      name = name + "_with_keys",
      image = base,
      keys = keys,
  )

  # Generate the script to download packages in the container and extract only
  # the deb packages tarball as the output.
  download_pkgs(
      name = name + "_pkgs",
      additional_repos = additional_repos,
      image_tar = ":" + name + "_with_keys.tar",
      packages = packages,
  )

  # Execute the package installation script in the container and commit the
  # resulting container locally as a new image named as {name}. The resulting
  # image is also available as target :{name}.tar.
  install_pkgs(
      name = name,
      image_tar = base,
      installables_tar = ":" + name + "_pkgs.tar",
      output_image_name = name,
  )

def _docker_toolchain_autoconfig_impl(ctx):
  """Implementation for the docker_toolchain_autoconfig rule.

  Args:
    ctx: context. See docker_toolchain_autoconfig below for details
        of what this ctx must include
  Returns:
    null
  """
  bazel_config_dir = "/bazel-config"
  project_repo_dir = "project_src"

  # Command to retrieve the project from github if requested.
  clone_repo_cmd = "cd ."
  if ctx.attr.git_repo:
    clone_repo_cmd = ("cd " + bazel_config_dir + " && git clone " +
                      ctx.attr.git_repo + " " + project_repo_dir)

  # Command to install custom Bazel version (if requested)
  install_bazel_cmd = "cd ."
  if ctx.attr.use_bazel_head:
    # If use_bazel_head was requested, we clone the source code from github and compile
    # it using the release version with "bazel build //src:bazel".
    install_bazel_cmd = "/install_bazel_head.sh"
  elif ctx.attr.bazel_version:
    if ctx.attr.bazel_rc_version:
      # If a specific Bazel and Bazel RC version is specified, install that version.
      # We bootstrap our Bazel binary using "bazel build", and cannot use ./compile.sh as it generates
      # cc binaries depending on incompatible dynamically linked libraries.
      bazel_url = ("https://releases.bazel.build/" +
                  ctx.attr.bazel_version + "/rc" + ctx.attr.bazel_rc_version +
                  "/bazel-" + ctx.attr.bazel_version + "rc" +
                  ctx.attr.bazel_rc_version + "-dist.zip")
      install_bazel_cmd = "/install_bazel_rc_version.sh " + bazel_url
    else:
      bazel_url = ("https://github.com/bazelbuild/bazel/releases/download/" +
                  ctx.attr.bazel_version +
                  "/bazel-" + ctx.attr.bazel_version + "-installer-linux-x86_64.sh")
      install_bazel_cmd = "/install_bazel_version.sh " + bazel_url

  # Command to recursively convert soft links to hard links in the config_repos
  deref_symlinks_cmd = []
  for config_repo in ctx.attr.config_repos:
    symlinks_cmd = ("find $(bazel info output_base)/" +
                    _EXTERNAL_FOLDER_PREFIX + config_repo +
                    " -type l -exec bash -c 'ln -f \"$(readlink -m \"$0\")\" \"$0\"' {} \;")
    deref_symlinks_cmd.append(symlinks_cmd)
  deref_symlinks_cmd = " && ".join(deref_symlinks_cmd)

  # Command to copy produced toolchain configs to outside of
  # the containter (to the mount_point).
  copy_cmd = []
  for config_repo in ctx.attr.config_repos:
    src_dir = "$(bazel info output_base)/" + _EXTERNAL_FOLDER_PREFIX + config_repo
    copy_cmd.append("cp -dr " + src_dir + " " + bazel_config_dir + "/")
    # We need to change the owner of the files we copied, so that they can
    # be manipulated from outside the container.
    copy_cmd.append("chown -R $USER_ID " + bazel_config_dir + "/" + config_repo)
  output_copy_cmd = " && ".join(copy_cmd)

  # Command to run autoconfigure targets.
  bazel_cmd = "cd " + bazel_config_dir + "/" + project_repo_dir
  if ctx.attr.use_default_project:
    bazel_cmd += " && touch WORKSPACE && mv BUILD.sample BUILD"
  # For each config repo we run the target @<config_repo>//...
  bazel_targets = "@" + "//... @".join(ctx.attr.config_repos) + "//..."
  bazel_flags = " --all_incompatible_changes"
  bazel_cmd += " && bazel build " + bazel_flags + " " + bazel_targets

  # Command to run to clean up after autoconfiguration.
  # we start with "cd ." to make sure in case of failure everything after the
  # ";" will be executed
  clean_cmd = "cd . ; bazel clean"
  if ctx.attr.use_default_project:
    clean_cmd += " && rm WORKSPACE"
  if ctx.attr.git_repo:
    clean_cmd += " && cd " + bazel_config_dir + " && rm -drf " + project_repo_dir

  # Full command to use for docker container
  # TODO(xingao): Make sure the command exits with error right away if a sub
  # command fails.
  docker_cmd = [
      "/bin/sh", "-c", " && ".join([
          "set -ex",
          ctx.attr.setup_cmd,
          install_bazel_cmd,
          "echo === Cloning project repo ===",
          clone_repo_cmd,
          "echo === Running Bazel autoconfigure command ===",
          bazel_cmd,
          "echo === Copying outputs ===",
          deref_symlinks_cmd,
          output_copy_cmd,
          "echo === Cleaning up ===",
          clean_cmd])]

  # Expand contents of repo_pkg_tar
  # (and remove them after we're done running the docker command).
  # A dummy command that does nothing in case git_repo was used
  expand_repo_cmd = "cd ."
  remove_repo_cmd = "cd ."
  if ctx.attr.repo_pkg_tar:
    repo_pkg_tar = str(ctx.attr.repo_pkg_tar.label.name)
    package_name = _EXTERNAL_FOLDER_PREFIX + _WORKSPACE_NAME + "/" + str(ctx.attr.repo_pkg_tar.label.package)
    # Expand the tar file pointed by repo_pkg_tar
    expand_repo_cmd = ("mkdir ./%s ; tar -xf %s/%s.tar -C ./%s" %
                       (project_repo_dir, package_name, repo_pkg_tar, project_repo_dir))
    remove_repo_cmd = ("rm -drf ./%s" % project_repo_dir)

  result = _container.image.implementation(ctx, cmd=docker_cmd, output_executable=ctx.outputs.load_image)

  # By default we copy the produced tar file to /tmp/
  output_location = "/tmp/" + ctx.attr.name + ".tar"
  if _DOCKER_AUTOCONF_OUTPUT in ctx.var:
    output_location = ctx.var[_DOCKER_AUTOCONF_OUTPUT] + "/" + ctx.attr.name + ".tar"
  # Create the script to load image and run it
  ctx.actions.expand_template(
      template = ctx.files.run_tpl[0],
      substitutions ={
          "%{EXPAND_REPO_CMD}": expand_repo_cmd,
          "%{LOAD_IMAGE_SH}": ctx.outputs.load_image.short_path,
          "%{IMAGE_NAME}": "bazel/" + ctx.label.package + ":" + ctx.label.name,
          "%{RM_REPO_CMD}": remove_repo_cmd,
          "%{CONFIG_REPOS}": " ".join(ctx.attr.config_repos),
          "%{OUTPUT}": output_location,
      },
      output = ctx.outputs.executable,
      is_executable = True
  )

  # add to the runfiles the script to load image and (if needed) the repo_pkg_tar file
  runfiles = ctx.runfiles(files = result.runfiles.files.to_list() + [ctx.outputs.load_image])
  if ctx.attr.repo_pkg_tar:
    runfiles = ctx.runfiles(files = result.runfiles.files.to_list() +
                            [ctx.outputs.load_image] + ctx.files.repo_pkg_tar)

  return struct(runfiles = runfiles,
                files = result.files,
                container_parts = result.container_parts)

docker_toolchain_autoconfig_ = rule(
    attrs = _container.image.attrs + {
        "config_repos": attr.string_list(["local_config_cc"]),
        "use_default_project": attr.bool(default = False),
        "git_repo": attr.string(),
        "repo_pkg_tar": attr.label(allow_files = tar_filetype),
        "bazel_version": attr.string(),
        "bazel_rc_version": attr.string(),
        "use_bazel_head": attr.bool(default = False),
        "run_tpl": attr.label(allow_files = True),
        "setup_cmd": attr.string(default = "cd ."),
        "packages": attr.string_list(),
        "additional_repos": attr.string_list(),
        "keys": attr.string_list(),
        "test": attr.bool(default = True),
    },
    executable = True,
    outputs = _container.image.outputs + {
        "load_image": "%{name}_load_image.sh",
    },
    implementation = _docker_toolchain_autoconfig_impl,
)

# Attributes below are expected in ctx, but should not be provided
# in the BUILD file.
reserved_attrs = [
    "use_default_project",
    "files",
    "debs",
    "repo_pkg_tar",
    "run_tpl",
    # all the attrs from docker_build we dont want users to set
    "directory",
    "tars",
    "legacy_repository_naming",
    "legacy_run_behavior",
    "docker_run_flags",
    "mode",
    "symlinks",
    "entrypoint",
    "cmd",
    "user",
    "labels",
    "ports",
    "volumes",
    "workdir",
    "repository",
    "label_files",
    "label_file_strings",
    "empty_files",
    "build_layer",
    "create_image_config",
    "sha256",
    "incremental_load_template",
    "join_layers",
    "extract_config",
]

# Attrs expected in the BUILD rule
required_attrs = [
    "base",
]

def docker_toolchain_autoconfig(**kwargs):
  """Generate toolchain configs for a docker container.

  This rule produces a tar file with toolchain configs produced from the
  execution of targets in skylark remote repositories. Typically, this rule is
  used to produce toolchain configs for the local_config_cc repository.
  This repo (as well as others, depending on the project) contains generated
  toolchain configs that Bazel uses to properly use a toolchain. For instance,
  the local_config_cc repo generates a cc_toolchain rule.

  The toolchain configs that this rule produces, can be used to, for
  instance, use a remote execution service that runs actions inside docker
  containers.

  All the toolchain configs published in the bazel-toolchains
  repo (https://github.com/bazelbuild/bazel-toolchains/) have been produced
  using this rule.

  This rule is implemented by extending the container_image rule in
  https://github.com/bazelbuild/rules_docker. The rule installs debs packages
  to run bazel (using the package manager rules offered by
  https://github.com/GoogleCloudPlatform/distroless/tree/master/package_manager).
  The rule creates the container with a command that pulls a repo from github,
  and runs bazel build for a series of remote repos. Files generated in these
  repos are copied to a mount point inside the Bazel output tree, and finally
  copied to the /tmp directory or to the DOCKER_AUTOCONF_OUTPUT directory
  if passed as build variable.

  Args:
    **kwargs:
  Required Args
    name: A unique name for this rule.
    base: Docker image base - optionally with all tools pre-installed for
        which a configuration will be generated. Packages can also be installed
        by listing them in the 'packages' attriute.
  Default Args:
    config_repos: a list of remote repositories. Autoconfig will run targets in
        each of these remote repositories and copy all contents to the mount
        point.
    env: Dictionary of env variables for Bazel / project specific autoconfigure
    git_repo: A git repo with the sources for the project to be used for
        autoconfigure. If no git_repo is passed, autoconfig will run with a
        sample c++ project.
    bazel_version: a specific version of Bazel used to generate toolchain
        configs. Format: x.x.x
    bazel_rc_version: a specific version of Bazel release candidate used to
        generate toolchain configs. Input "2" if you would like to use rc2.
    use_bazel_head = Download bazel head from github, compile it and use it
        to run autoconfigure targets.
    setup_cmd: a customized command that will run as the very first command
        inside the docker container.
    packages: list of packages to fetch and install in the base image.
    additional_repos: list of additional debian package repos to use,
        in sources.list format.
    keys: list of additional gpg keys to use while downloading packages.
    test: a boolean which specifies whether a test target for this
        docker_toolchain_autoconfig will be added.
        If True, a test target with name {name}_test will be added.
        The test will build this docker_toolchain_autoconfig target, run the
        output script, and check the toolchain configs for the c++ auto
        generated config exist.
  """
  for reserved in reserved_attrs:
    if reserved in kwargs:
      fail("reserved for internal use by docker_toolchain_autoconfig macro", attr=reserved)

  for required in required_attrs:
    if required not in kwargs:
      fail("required for docker_toolchain_autoconfig", attr=required)

  # Input validations
  if "use_bazel_head" in kwargs and ("bazel_version" in kwargs or "bazel_rc_version" in kwargs):
    fail ("Only one of use_bazel_head or a combination of bazel_version and" +
          "bazel_rc_version can be set at a time.")

  packages_is_empty = "packages" not in kwargs or kwargs["packages"] == []

  if packages_is_empty and "additional_repos" in kwargs:
    fail("'additional_repos' can only be specified when 'packages' is not empty.")
  if packages_is_empty and "keys" in kwargs:
    fail("'keys' can only be specified when 'packages' is not empty.")

  # If the git_repo was not provided, use the default autoconfig project
  if "git_repo" not in kwargs:
    kwargs["repo_pkg_tar"] = _DEFAULT_AUTOCONFIG_PROJECT_PKG_TAR
    kwargs["use_default_project"] = True
  kwargs["files"] = [
      _WORKSPACE_PREFIX + "rules:install_bazel_head.sh",
      _WORKSPACE_PREFIX + "rules:install_bazel_version.sh",
      _WORKSPACE_PREFIX + "rules:install_bazel_rc_version.sh"
  ]

  # The template for the main script to execute for this rule, which produces
  # the toolchain configs
  kwargs["run_tpl"] = _WORKSPACE_PREFIX + "rules:docker_config.sh.tpl"

  # Do not install packags if 'packages' is not specified or is an ampty list.
  if not packages_is_empty:
    # "additional_repos" and "keys" are optional for docker_toolchain_autoconfig,
    # but required for container_install_pkgs". Use empty lists as placeholder.
    if "additional_repos" not in kwargs:
      kwargs["additional_repos"] = []
    if "keys" not in kwargs:
      kwargs["keys"] = []

    # Install packages in the base image.
    container_install_pkgs(
      name = kwargs["name"] + "_image",
      base = kwargs["base"],
      packages = kwargs["packages"],
      additional_repos = kwargs["additional_repos"],
      keys = kwargs["keys"],
    )

    # Use the image with packages installed as the new base for autoconfiguring.
    kwargs["base"] = ":" + kwargs["name"] + "_image.tar"

  if "test" in kwargs and kwargs["test"] == True:
    # Create a test target for the current docker_toolchain_autoconfig target,
    # which builds this docker_toolchain_autoconfig target, runs the output
    # script, and checks the toolchain configs for the c++ auto generated config
    # exist.
    native.sh_test(
      name = kwargs["name"] + "_test",
      size = "medium",
      timeout = "long",
      srcs = ["//test/configs:autoconfig_test.sh"],
      data = [":" + kwargs["name"]],
    )

  docker_toolchain_autoconfig_(**kwargs)
