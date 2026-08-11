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
    compileSdk = 37
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
            
            // Disabilita linting per evitare problemi con Android SDK 37
            lint {
                checkReleaseBuilds = false
            }
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.0")

    // Firebase/FCM: solo per il flavor playstore
    "playstoreImplementation"(platform("com.google.firebase:firebase-bom:33.16.0"))
    "playstoreImplementation"("com.google.firebase:firebase-messaging")
}

// Esclude le librerie Firebase/GMS da TUTTE le configurazioni del flavor fdroid
// Garantisce che l'APK F-Droid sia privo di qualsiasi bytecode Google Firebase
configurations.matching { it.name.startsWith("fdroid") }.configureEach {
    exclude(group = "com.google.firebase")
    exclude(group = "com.google.android.gms")
    exclude(group = "com.google.android.datatransport")
}

configurations.all {
    exclude(group = "com.google.crypto.tink", module = "tink")
}

// Applica il plugin google-services SOLO per il flavor playstore
// (richiede google-services.json solo in quel caso)
if (gradle.startParameter.taskNames.any { it.contains("playstore", ignoreCase = true) }) {
    apply(plugin = "com.google.gms.google-services")
}

// Disabilita la generazione automatica di GeneratedPluginRegistrant da parte di Flutter.
// Forniamo i registranti manualmente nei source set fdroid e playstore per garantire
// che la build F-Droid non contenga alcun riferimento a classi Firebase.
afterEvaluate {
    tasks.matching {
        it.name.startsWith("generatePlugin") && it.name.endsWith("RegistrantFile")
    }.configureEach {
        enabled = false
    }
}
