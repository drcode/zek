# ZEK: Take Roam-like Notes in a Line Editor, Written in Zig

https://www.youtube.com/watch?v=4W_m176PIdU

"ZEK" stands for "Zig Editor of Knowledge". It is written in ziglang for maximum performance. It is based on the Zettelkasten system, also called a PKMS, or a "roam-like" editor. It let's you create notes that are deeply linked, without hierarchies. It supports backlinks. Zek was created by Conrad Barski (The author of "Land of Lisp" as well as other books) and is available as open source at https://github.com/drcode/zek

Follow conrad on twitter at: www.twitter.com/lisperati

# Installing ZEK

To use ZEK, simply put the ZEK executable on the path for your OS. The repository contains three pre-built x86 executable files (`zek_linux`, `zek_macos`, or `zek_windows.exe`) which you should rename to 'zek'. Then, set up a new directory on your PC that will contain your database files. Place the file `help.md` in this directory, for easy access to help information, via the 'h' key.

# Building ZEK

If you have another OS or CPU, install the zig programming language on your computer (last tested with zig version 0.9.0-dev.1374+8b8827478) and then run `zig build` to generate an executable for your purpose in the `zig-out/bin` directory.

# Running ZEK

Simply execture `zek` from the directory where you want your database files to live. Now follow the youtube video above for basic usage, and hit 'h' for a full list of commands.

# FAQ

Q: What is the command for creating a page?
A:To create a page, simply link to the page in square brackets from another page. The only pages that can exist without a link from another page are the calendar pages (which have a date in the title)

Q: Why do the files for date pages have pipe symbols in them?
A: Most OSes don't like file names with slashes. However, when referencing date pages from within zek you can just use reference dates with the usual hyphens.

Q: How do I rename a page? You do this by editing the root node of the page outline, which contains the name of the page. To do this, simply perform the edit command `e` without any path.
