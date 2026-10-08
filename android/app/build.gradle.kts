import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.loomilabs.superduperch"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.loomilabs.superduperch"
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }
}

// A distributed artifact must never carry the debug certificate. The check
// runs as a task action, so the configuration cache accepts it.
val allowDebugSigning = project.findProperty("allowDebugSigning")?.toString() == "true"

if (!keystorePropertiesFile.exists()) {
    tasks.configureEach {
        val signsRelease = name.contains("Release") &&
            listOf("assemble", "bundle", "package", "signingConfigWriter").any { name.startsWith(it) }
        if (signsRelease) {
            doFirst {
                if (allowDebugSigning) {
                    logger.warn("WARNING: signing the release build with the DEBUG certificate. Do not distribute it.")
                } else {
                    throw GradleException(
                        "key.properties is missing, so the release build would be signed with the debug " +
                            "certificate. Add key.properties, or set ORG_GRADLE_PROJECT_allowDebugSigning=true for a local build."
                    )
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
