pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
rootProject.name = "demo"
include(":logging")
project(":logging").projectDir = file("..")
