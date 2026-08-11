import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // google-services viene applicato solo se il flavor lo richiede (vedi sotto)
}

// Leggi key.properties se esiste (non committato nel repo)
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "work.dreadful.catchme"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "work.dreadful.catchme"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasKeystore) {
                signingConfig = signingConfigs.create("release").apply {
                    keyAlias = keystoreProperties["keyAlias"] as String
                    keyPassword = keystoreProperties["keyPassword"] as String
                    storeFile = file(keystoreProperties["storeFile"] as String)
                    storePassword = keystoreProperties["storePassword"] as String
                }
            } else {
                // Fallback: firma debug (solo per test, non per distribuzione)
                signingConfig = signingConfigs.getByName("debug")
            }
            
            // Disabilita R8 per evitare problemi di compatibilità
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    flavorDimensions += "distribution"

    productFlavors {
        create("fdroid") {
            dimension = "distribution"
            applicationIdSuffix = ""
            // Flavor FOSS: UnifiedPush only, no Firebase
        }
        create("playstore") {
            dimension = "distribution"
            applicationIdSuffix = ""
            // Flavor completo: FCM + UnifiedPush
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        apiVersion = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2
        languageVersion = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // Firebase/FCM: solo per il flavor playstore
    "playstoreImplementation"(platform("com.google.firebase:firebase-bom:33.0.0"))
    "playstoreImplementation"("com.google.firebase:firebase-messaging")
}

configurations.all {
    exclude(group = "com.google.crypto.tink", module = "tink")
}

// Applica il plugin google-services SOLO per il flavor playstore
// (richiede google-services.json solo in quel caso)
if (gradle.startParameter.taskNames.any { it.contains("playstore", ignoreCase = true) }) {
    apply(plugin = "com.google.gms.google-services")
}
