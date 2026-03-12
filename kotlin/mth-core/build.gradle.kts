plugins {
    alias(libs.plugins.kotlin.jvm)
    `maven-publish`
}

group = "com.github.ncmud.mth"
version = project.findProperty("VERSION") ?: "unspecified"

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
            artifactId = "mth-core"
        }
    }
}

dependencies {
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
