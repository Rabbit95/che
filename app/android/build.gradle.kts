allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Backfill `namespace` for older Flutter plugins that still rely on the
// AndroidManifest `package` attribute (removed by AGP 8+). Reads the
// manifest's package= and injects it as android.namespace. Must be
// registered before the `evaluationDependsOn` block below.
subprojects {
    plugins.withId("com.android.library") {
        val androidExt = extensions.findByName("android") ?: return@withId
        val setNamespace = androidExt.javaClass.methods.firstOrNull { it.name == "setNamespace" }
            ?: return@withId
        val getNamespace = androidExt.javaClass.methods.firstOrNull { it.name == "getNamespace" }
        val current = getNamespace?.invoke(androidExt) as String?
        if (!current.isNullOrBlank()) return@withId

        val manifest = file("src/main/AndroidManifest.xml")
        if (!manifest.exists()) return@withId
        val pkg = Regex("""package\s*=\s*"([^"]+)"""")
            .find(manifest.readText())?.groupValues?.getOrNull(1)
            ?: return@withId
        setNamespace.invoke(androidExt, pkg)
        logger.lifecycle("[namespace-fix] set namespace=$pkg for :${project.name}")
    }
}

// Force every :plugin subproject's compileSdk up to the app's target.
// Rationale: old plugins (quick_usb 0.4.0 pins compileSdkVersion 31; libusb
// et al. similar) fail to compile against a modern toolchain because the
// SDK Platform they hardcode either isn't installed on the machine or is
// too old for constants they later reference (Build.VERSION_CODES.S,
// PendingIntent.FLAG_MUTABLE). Overriding at afterEvaluate time is the
// canonical Flutter-community workaround.
//
// AGP renamed setCompileSdkVersion(int) → setCompileSdk(int) between 7.x
// and 8.x, so we try both. Everything is wrapped in try/catch: if one
// plugin trips us up we log and move on rather than failing the whole
// evaluation (which surfaces as the unhelpful "Failed to notify project
// evaluation listener" message).
subprojects {
    plugins.withId("com.android.library") {
        afterEvaluate {
            val androidExt = extensions.findByName("android") ?: return@afterEvaluate
            try {
                val candidates = listOf("setCompileSdk", "setCompileSdkVersion")
                val setter = candidates.firstNotNullOfOrNull { name ->
                    androidExt.javaClass.methods.firstOrNull { m ->
                        m.name == name &&
                            m.parameterTypes.size == 1 &&
                            m.parameterTypes[0] == Int::class.javaPrimitiveType
                    }
                }
                if (setter == null) {
                    logger.warn("[compileSdk-fix] no setter found on :${project.name}")
                    return@afterEvaluate
                }
                setter.invoke(androidExt, 36)
                logger.lifecycle("[compileSdk-fix] pinned :${project.name} compileSdk=36 via ${setter.name}")
            } catch (e: Throwable) {
                logger.warn("[compileSdk-fix] SKIPPED :${project.name}: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
