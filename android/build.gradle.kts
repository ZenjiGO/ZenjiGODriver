allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Raise compileSdk to 36 for any plugin module compiled against an older Android API
// (e.g. file_picker 8.x uses 34, but AndroidX lifecycle now requires 36+).
subprojects {
    val raiseCompileSdk: Project.() -> Unit = {
        try {
            val ext = extensions.findByName("android")
            if (ext != null) {
                val current = try {
                    ext.javaClass.getMethod("getCompileSdk").invoke(ext) as? Int
                } catch (_: Exception) {
                    null
                }
                if (current == null || current < 36) {
                    ext.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType).invoke(ext, 36)
                }
            }
        } catch (_: Exception) {
            // leave the module as-is if its extension does not expose these methods
        }
    }
    if (state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
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

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}