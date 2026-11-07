import org.jetbrains.kotlin.gradle.dsl.JvmTarget
plugins {
    kotlin("multiplatform") version "2.3.21"
    id("com.android.library") version "8.13.2"
}
group = "com.proxycept"
version = "0.1.0"
kotlin {
    jvmToolchain(17)
    jvm { compilerOptions { jvmTarget.set(JvmTarget.JVM_1_8) } }
    androidTarget { compilerOptions { jvmTarget.set(JvmTarget.JVM_1_8) } }
    iosArm64 { binaries.framework { baseName = "ProxyceptLoggingKmp"; isStatic = true } }
    iosSimulatorArm64 { binaries.framework { baseName = "ProxyceptLoggingKmp"; isStatic = true } }
    applyDefaultHierarchyTemplate()
    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.2")
            implementation("com.squareup.okio:okio:3.9.1")
        }
        commonTest.dependencies { implementation(kotlin("test")); implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.1") }
        val javaMain by creating { dependsOn(commonMain.get()); dependencies { implementation("com.squareup.okhttp3:okhttp:4.12.0") } }
        jvmMain.get().dependsOn(javaMain)
        androidMain.get().dependsOn(javaMain)
        jvmTest.dependencies { implementation(kotlin("test-junit")) }
    }
}
android {
    namespace = "com.proxycept.logging.kmp"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_1_8; targetCompatibility = JavaVersion.VERSION_1_8 }
}
tasks.withType<Test>().configureEach {
    testLogging { events("passed", "failed", "skipped") }
    systemProperty("proxycept.conformance", file("../conformance/attribute-vectors.json").absolutePath)
}
tasks.register<JavaExec>("localSmoke") {
    group = "verification"
    description = "Explicit local-only API smoke; credentials come from environment, never arguments."
    val main = kotlin.targets.getByName("jvm").compilations.getByName("main")
    dependsOn(main.compileTaskProvider)
    classpath = files(main.output.allOutputs, configurations.getByName("jvmRuntimeClasspath"))
    mainClass.set("com.proxycept.logging.kmp.LocalSmokeKt")
}

// Development-only relative fixture; generated test source is never packaged in the SDK.
val generateConformance by tasks.registering {
    val fixture = file("../conformance/attribute-vectors.json")
    val output = layout.buildDirectory.file("generated/conformance/com/proxycept/logging/kmp/ConformanceFixture.kt")
    inputs.file(fixture); outputs.file(output)
    doLast {
        output.get().asFile.apply {
            parentFile.mkdirs()
            writeText("package com.proxycept.logging.kmp\ninternal fun conformanceFixtureText(): String = byteArrayOf(" +
                fixture.readBytes().joinToString(",") { it.toString() } + ").decodeToString()\n")
        }
    }
}
kotlin.sourceSets.commonTest { kotlin.srcDir(layout.buildDirectory.dir("generated/conformance")) }
tasks.matching { it.name.contains("compile", true) && it.name.contains("Test", true) }.configureEach { dependsOn(generateConformance) }
tasks.register("prepareLocalSmoke") {
    val main = kotlin.targets.getByName("jvm").compilations.getByName("main")
    dependsOn(main.compileTaskProvider)
    val output = layout.buildDirectory.file("smoke-classpath.txt")
    inputs.files(main.output.allOutputs, configurations.getByName("jvmRuntimeClasspath"))
    outputs.file(output)
    doLast { output.get().asFile.writeText(files(main.output.allOutputs, configurations.getByName("jvmRuntimeClasspath")).asPath) }
}
