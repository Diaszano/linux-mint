# Gradle resource guidance

## Default recipe

Use the project wrapper through the scoped build command and disable reuse of a daemon from an earlier build:

```sh
dev-build ./gradlew assembleDebug --no-daemon
```

`dev-build` sets `GOMAXPROCS=8`, `CARGO_BUILD_JOBS=4`, and `CMAKE_BUILD_PARALLEL_LEVEL=4` for the child workload only when each variable is unset. Explicit values in the caller's environment are preserved, and no shell profile or project file is changed.

Gradle's `--no-daemon` prevents reuse of a persistent daemon, but Gradle may still start a single-use daemon when JVM arguments differ from the client. A single-use daemon, compiler process, and worker started by the command remain in the verified `dev-build` cgroup. The wrapper does not move an already-running daemon into that cgroup; commands that reuse one are outside the isolation guarantee. Builds started directly from Android Studio are also outside it.

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
