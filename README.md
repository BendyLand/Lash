# Lash (Labeled Bash)

Lash is a lightweight, dependency-free alternative to tools like make or just. Written in Zig, it offers a small binary and a simple workflow for running named bash command blocks defined in a lashfile.
Overview

Lash reads a file named lashfile, parses labeled sections (similar to Makefile targets or Justfile recipes), and executes the shell commands associated with the requested label.
Why Lash?

 - Small binary: implemented in Zig for minimal footprint
 - Simple syntax: just write Bash under a label
 - No dependencies: runs on any POSIX system with /bin/sh

## Example

Your lashfile might look like this:

```just
build:
    echo "Compiling..."
    zig build

clean:
    rm -rf zig-cache
    echo "Cleaned."
```

Then run:

```just
lash build
```

This executes the build section in a temporary shell script.

## Usage

```just
lash <section>
```
 - <section> is the label of the command block you want to run.
 - lashfile must be present in the current working directory.
 - Commands must be indented (with spaces or tabs) beneath a label ending in :.

## Notes

 - The contents of each section are wrapped in a temporary bash script and executed.
 - Errors during command execution are printed to stderr.
 - File permissions are handled automatically for the temporary script.
 - Output is streamed to stdout.

## Building

To build Lash from source (requires Zig):

```bash
zig build --release=small # for the main benefit over just
```

## License

This project is licensed under the [MIT License](./LICENSE).

