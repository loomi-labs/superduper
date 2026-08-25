import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "io.kbl.superduper"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

    defaultConfig {
        applicationId = "io.kbl.superduper"
        // You can update the following values to match your application needs.
        // For more information, see: https://docs.flutter.dev/deployment/android#reviewing-the-build-configuration.
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Debug signing here is a local-build convenience only. The
            // task-graph check below stops it reaching a real release artifact.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

// A distributed artifact must never carry the debug certificate. Checked on the
// task graph, not in the buildTypes block above: that block configures on every
// Gradle invocation, so a failure there would break debug builds too.
//
// Both values are read now, at configuration time. Reading them inside the
// callback would touch `project` at execution time, which the configuration
// cache forbids.
val allowDebugSigning = project.hasProperty("allowDebugSigning")
val buildLogger = logger

if (!keystorePropertiesFile.exists()) {
    // No lambda parameter: the Kotlin DSL takes a TaskExecutionGraph receiver,
    // so `allTasks` is read off `this`. A parameter here would bind to the
    // Groovy Closure overload instead, which does not compile.
    gradle.taskGraph.whenReady {
        val buildsRelease = allTasks.any { task ->
            task.name.contains("Release") &&
                listOf("assemble", "bundle", "package").any { task.name.startsWith(it) }
        }
        if (buildsRelease) {
            if (allowDebugSigning) {
                buildLogger.warn(
                    "WARNING: signing the release build with the DEBUG certificate. " +
                        "This artifact is for local testing only. Do not distribute it."
                )
            } else {
                throw GradleException(
                    "key.properties is missing, so the release build would be signed " +
                        "with the debug certificate. Add key.properties, or set " +
                        "ORG_GRADLE_PROJECT_allowDebugSigning=true for a local build."
                )
            }
        }
    }
}

flutter { source = "../.." }