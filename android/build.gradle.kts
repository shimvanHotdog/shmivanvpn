plugins {
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
}

// This repo may live in an iCloud-synced folder; iCloud skips "*.nosync" and won't litter build output with "file 2" copies.
allprojects {
    layout.buildDirectory = layout.projectDirectory.dir("build.nosync")
}
