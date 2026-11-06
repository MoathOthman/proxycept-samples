plugins {
    kotlin("jvm") version "2.1.0" apply false
    id("com.android.application") version "8.7.3"
    kotlin("android") version "2.1.0"
}
repositories { google(); mavenCentral() }
android {
    namespace = "com.proxycept.loggingdemo"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.proxycept.loggingdemo"
        minSdk = 21
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "com.proxycept.loggingdemo.SmokeInstrumentation"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8) } }
dependencies { implementation(project(":logging")) }
