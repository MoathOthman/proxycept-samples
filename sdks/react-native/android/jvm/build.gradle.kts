plugins { kotlin("jvm") version "2.1.0" }
repositories { mavenCentral() }
kotlin { jvmToolchain(17) }
sourceSets {
    main { kotlin.srcDir("../src/main/java/com/proxycept/reactnative/core") }
    test { kotlin.srcDir("../src/test/java") }
}
dependencies {
    implementation("com.google.code.gson:gson:2.11.0")
    testImplementation(kotlin("test-junit"))
    testImplementation("junit:junit:4.13.2")
}
tasks.test {
    systemProperty("proxycept.conformance", file("../../../conformance/attribute-vectors.json").absolutePath)
    testLogging { events("passed", "failed", "skipped") }
}
