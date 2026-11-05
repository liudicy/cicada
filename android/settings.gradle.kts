// Cicada for Android: core (pure-JVM engines), cli (tests + real runs on the Mac), app (the APK).
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "cicada-android"
include(":core", ":cli", ":app", ":tools:player")
