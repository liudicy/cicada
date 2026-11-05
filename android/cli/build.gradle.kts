// cicada-cli: the engines without Android. `test` runs the unit tests; `listen`, `hear`,
// `segments` and `roundtrip` run them for real on the Mac (scripts/cli.sh).
plugins { id("org.jetbrains.kotlin.jvm"); application }
kotlin { jvmToolchain(21) }
dependencies { implementation(project(":core")) }
application { mainClass = "cicada.cli.MainKt"; applicationName = "cicada-cli" }
