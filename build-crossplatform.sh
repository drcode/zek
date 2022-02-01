rm zek_linux
rm zek_windows.exe
rm zek_macos
zig build
mv zig-out/bin/zek zek_linux
zig build-exe src/zek.zig -target x86_64-windows
mv zek.exe zek_windows.exe
zig build-exe src/zek.zig -target x86_64-macos
mv zek zek_macos
