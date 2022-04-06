rm zek_linux
rm zek_windows.exe
rm zek_macos_x86
rm zek_macos_M1
rm zek_pi_zero_1
zig build -Dtarget=x86_64-linux
mv zig-out/bin/zek zek_linux
zig build-exe src/zek.zig -target x86_64-windows
mv zek.exe zek_windows.exe
zig build-exe src/zek.zig -target x86_64-macos
mv zek zek_macos_x86
zig build-exe src/zek.zig -target aarch64-macos
mv zek zek_macos_M1
zig build -Dtarget=arm-linux-musleabi -Dcpu=arm1176jzf_s
mv zig-out/bin/zek zek_pi_zero_1
