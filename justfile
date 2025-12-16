# bootstrapping with a lashfile breaks its behavior
run:
    zig run src/main.zig --library c -- first

build:
    zig build --release=small
    mv zig-out/bin/lash .
    
