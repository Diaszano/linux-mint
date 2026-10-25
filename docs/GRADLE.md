# Gradle resource guidance

## Default recipe

Use the project wrapper through the scoped build command and disable reuse of a daemon from an earlier build:

```sh
dev-build ./gradlew assembleDebug --no-daemon
```

Gradle can still create a single-use daemon when the requested JVM options differ from the client process. That daemon and its workers are expected to remain inside the `dev-build` cgroup; an already-running daemon reused by another process and builds started directly from Android Studio are outside the generic wrapper guarantee.

The default setup only prints this guidance. It does not write project files or Gradle user properties.

## Optional Gradle user properties

`setup.sh --gradle-global` previews an optional managed block under `${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties`. Apply requires a separate explicit confirmation token from that preview. The block proposes:

```properties
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=768m
org.gradle.workers.max=4
org.gradle.caching=true
org.gradle.daemon.idletimeout=900000
```

These are provisional user-level defaults, not measured performance improvements. The 3 GiB heap is only the Gradle daemon Java heap: total build memory also includes metaspace, native allocations, compiler processes, workers, the Gradle client, the emulator, and other desktop applications. The separate `dev-run` cgroup limits remain the memory safety boundary.

Gradle reads user-home `gradle.properties` before project-root and installation `gradle.properties`, so the user-level block can override project settings unless a command-line option takes precedence. The installer refuses to shadow any of its keys already set outside its own block, preserves unrelated lines and file permissions, and rollback refuses if the file changed afterward. See [Gradle build environment configuration](https://docs.gradle.org/current/userguide/build_environment.html) for the documented property locations and precedence.

Global parallel execution and configuration-cache settings are intentionally omitted. Enable those only in a project after verifying plugin and build compatibility.
