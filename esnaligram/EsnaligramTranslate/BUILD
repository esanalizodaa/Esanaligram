load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "EsnaligramTranslate",
    module_name = "EsnaligramTranslate",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"] if False else [],
    visibility = ["//visibility:public"],
)
