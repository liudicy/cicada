// The engines: Kotlin stdlib and java.* only, so they build, test and run on the Mac.
plugins { id("org.jetbrains.kotlin.jvm") }
kotlin { jvmToolchain(21) }
java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 }
}
tasks.withType<JavaCompile>().configureEach { options.release = 17 }
