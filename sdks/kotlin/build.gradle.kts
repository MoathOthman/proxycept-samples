plugins {
    kotlin("jvm") version "2.1.0"
    `java-library`
}
group = "com.proxycept"
version = "0.1.0"
repositories { mavenCentral() }
kotlin { jvmToolchain(17); compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8) } }
tasks.withType<JavaCompile>().configureEach { options.release.set(8) }
dependencies {
    implementation("com.google.code.gson:gson:2.11.0")
    testImplementation(kotlin("test-junit"))
    testImplementation("junit:junit:4.13.2")
}
tasks.test { testLogging { events("passed", "failed", "skipped") } }
// Keep the artifact name stable when included under a different Gradle project name.
tasks.jar { archiveBaseName.set("proxycept-logging") }
