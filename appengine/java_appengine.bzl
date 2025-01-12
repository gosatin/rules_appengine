# Copyright 2015 The Bazel Authors. All rights reserved.
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
"""Java AppEngine support for Bazel.

For now, it only support bundling a WebApp and running locally.

To create a WebApp for Google AppEngine, add the rules:
appengine_war(
  name = "MyWebApp",
  # Jars to use for the classpath in the webapp.
  jars = ["//java/com/google/examples/mywebapp:java"],
  # data to put in the webapp, the directory structure of the data set
  # will be maintained.
  data = ["//java/com/google/examples/mywebapp:data"],
  # Data's root path, it will be considered as the root of the data files.
  # If unspecified, the path to the current package will be used. The path is
  # relative to current package or, relative to the workspace root if starting
  # with a leading slash.
  data_path = "/java/com/google/examples/mywebapp",
)

To test locally:
bazel run :MyWebApp

To deploy on Google app engine:
bazel run :MyWebApp.deploy

You can also make directly a single target for it with:

java_war(
  name = "MyWebApp",
  srcs = glob(["**/*.java"]),
  resources = ["..."],
  data = ["..."],
  data_path = "...",
)

Resources will be put in the classpath whereas data will be bundled at the root
of the war file. This is strictly equivalent to (it is actually a convenience
macros that translate to that):

java_library(
  name = "libMyWebApp",
  srcs = glob(["**/*.java"]),
  resources = ["..."],
)

appengine_war(
  name = "MyWebApp",
  jars = [":libMyWebApp"],
  data = ["..."],
  data_path = "...",
)

Finally, the appengine macro also create a .deploy target that will try to use the
AppEngine SDK to upload your application to AppEngine. It takes an optional argument: the
APP_ID. If not specified, it uses the default APP_ID provided in the application
web.xml.
"""


load(":variables.bzl", "JAVA_SDK_VERSION", "JAVA_SDK_SHA256")
load(":sdk.bzl", "find_locally_or_download")
load("@bazel_tools//tools/build_defs/repo:jvm.bzl", "jvm_maven_import_external")


jar_filetype = [".jar"]

def _add_file(in_file, output, path = None):
  output_path = output
  input_path = in_file.path
  if path and in_file.short_path.startswith(path):
    output_path += in_file.short_path[len(path):]
  return [
      "mkdir -p $(dirname %s)" % output_path,
      "test -L %s || ln -s $(pwd)/%s %s" % (output_path, input_path, output_path)
      ]

def _make_war(zipper, input_dir, output):
  return [
      "(root=$(pwd);" +
      ("cd %s &&" % input_dir) +
      ("find . ! -type d > $root/file_list &&") +
      ("${root}/%s Cc ${root}/%s @${root}/file_list)" % (zipper.path, output.path))
      ]

def _terminating(cond):
    """An easy way to break out of a generator"""
    if cond:
        return True


def _common_substring(str1, str2):
    answer = ""
    len1, len2 = len(str1), len(str2)
    for i in range(len1):
        match = ""
        for j in range(len2):
            if (i + j < len1 and str1[i + j] == str2[j]):
                match += str2[j]
            else:
                if (len(match) > len(answer)): answer = match
                match = ""
    return answer


def _short_path_dirname(path):
  sp = path.short_path
  return sp[0:len(sp)-len(path.basename)-1]

def _war_impl(ctxt):
  """Implementation of the rule that creates
     - the war
     - the script to deploy
  """
  zipper = ctxt.file._zipper

  data_path = ctxt.attr.data_path
  if not data_path:
    data_path = _short_path_dirname(ctxt.outputs.war)
  elif data_path[0] == "/":
    data_path = data_path[1:]
  else:  # relative path
    data_path = _short_path_dirname(ctxt.outputs.war) + "/" + data_path

  war = ctxt.outputs.war
  build_output = war.path + ".build_output"
  cmd = [
      "set -e;rm -rf " + build_output,
      "mkdir -p " + build_output
      ]

  inputs = [zipper]
  cmd += ["mkdir -p %s/WEB-INF/lib" % build_output]


  transitive_deps = []
  for jar in ctxt.attr.jars:
    if hasattr(jar, "java"):  # java_library, java_import
      transitive_deps += jar.java.transitive_runtime_deps
    elif hasattr(jar, "files"):  # a jar file
      transitive_deps += jar.files.to_list()


  for dep in transitive_deps:
    cmd += _add_file(dep, build_output + "/WEB-INF/lib")
    inputs.append(dep)

  for jar in ctxt.files._appengine_deps:
    cmd += _add_file(jar, build_output + "/WEB-INF/lib")
    inputs.append(jar)

  inputs += ctxt.files.data
  for res in ctxt.files.data:
    # Add the data file
    cmd += _add_file(res, build_output, path = data_path)

  cmd += _make_war(zipper, build_output, war)

  ctxt.actions.run_shell(
      inputs = inputs,
      outputs = [war],
      mnemonic="WAR",
      command="\n".join(cmd),
      use_default_shell_env=True)

  executable = ctxt.outputs.executable
  appengine_sdk = None
  for f in ctxt.files._appengine_sdk:
    if not appengine_sdk:
      appengine_sdk = f.short_path
    elif not f.path.startswith(appengine_sdk):
      appengine_sdk = _common_substring(appengine_sdk, f.short_path)
  if not appengine_sdk:
    fail("could not find appengine files",
         attr = str(ctxt.attr._appengine_sdk.label))

  classpath = ["${JAVA_RUNFILES}/%s" % jar.short_path for jar in transitive_deps]
  classpath += [
      "${JAVA_RUNFILES}/%s" % jar.short_path
      for jar in ctxt.files._appengine_deps
  ]

  substitutions = {
      "%{workspace_name}" : ctxt.workspace_name,
      "%{zipper}": ctxt.file._zipper.short_path,
      "%{war}": ctxt.outputs.war.short_path,
      "%{java}": ctxt.file._java.short_path,
      "%{appengine_sdk}": appengine_sdk,
      "%{classpath}":  (":".join(classpath)),
      "%{data_path}": data_path
  }

  ctxt.actions.expand_template(
      output = executable,
      template = ctxt.file._runner_template,
      substitutions = substitutions,
      is_executable = True)
  ctxt.actions.expand_template(
      output = ctxt.outputs.deploy_sh,
      template = ctxt.file._deploy_template,
      substitutions = substitutions,
      is_executable = True)

  runfiles = ctxt.runfiles(files = [war, executable]
                           + list(transitive_deps)
                           + inputs
                           + ctxt.files._appengine_sdk
                           + [ctxt.file._java, ctxt.file._zipper])
  return struct(runfiles = runfiles)

appengine_war_base = rule(
    _war_impl,
    attrs = {
        "_java": attr.label(
            default = Label("@bazel_tools//tools/jdk:java"),
	        allow_single_file = True,
        ),
        "_zipper": attr.label(
            default = Label("@bazel_tools//tools/zip:zipper"),
	    allow_single_file = True,
        ),
        "_runner_template": attr.label(
            default = Label("//appengine/java:runner_template"),
	        allow_single_file = True,
        ),
        "_deploy_template": attr.label(
            default = Label("//appengine/java:deploy_template"),
	        allow_single_file = True,
        ),
        "_appengine_sdk": attr.label(
            default = Label("@com_google_appengine_java//:sdk"),
        ),
        "_appengine_deps": attr.label_list(
            default = [Label("@com_google_appengine_java//:api")],
        ),
        "jars": attr.label_list(
            allow_files = jar_filetype,
            mandatory = True,
        ),
        "data": attr.label_list(allow_files = True),
        "data_path": attr.string(),
    },
    executable = True,
    outputs = {
        "war": "%{name}.war",
        "deploy_sh": "%{name}_deploy.sh",
    },
)

def java_war(name, data=[], data_path=None, **kwargs):
  """Convenience macro to call appengine_war with Java sources rather than jar.
  """
  native.java_library(name = "lib%s" % name, **kwargs)
  appengine_war(name = name,
                jars = ["lib%s" % name],
                data=data,
                data_path=data_path)

def appengine_war(name, jars, data, data_path, testonly = 0):
  """Convenience macro that builds the war and offers an executable
     target to deploy on Google app engine.
  """
  appengine_war_base(
      name = name,
      jars = jars,
      data = data,
      data_path = data_path,
      testonly = testonly,
  )
  # Create the executable rule to deploy
  native.sh_binary(
      name = "%s.deploy" % name,
      srcs = ["%s_deploy.sh" % name],
      data = [name],
      testonly = testonly,
  )

def java_appengine_repositories(version=JAVA_SDK_VERSION,
                                sha256=JAVA_SDK_SHA256):
  find_locally_or_download(
      name = "com_google_appengine_java",
      lang = "java",
      sha256 = sha256,
      version = version,
      filename_pattern = "appengine-java-sdk-{version}.zip",
      strip_prefix_pattern = "appengine-java-sdk-{version}",
  )

  jvm_maven_import_external(
      name = "javax_servlet_api",
      artifact = "javax.servlet:servlet-api:2.5",
      artifact_sha256 = "c658ea360a70faeeadb66fb3c90a702e4142a0ab7768f9ae9828678e0d9ad4dc",
      server_urls = ["https://repo1.maven.org/maven2/"],
      licenses = ["notice"],  # Apache 2.0
  )

