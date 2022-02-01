# ZEK: Take Roam-like Notes in a Line Editor, Written in Zig

https://www.youtube.com/watch?v=4W_m176PIdU

"ZEK" stands for "Zig Editor of Knowledge". It is written in ziglang for maximum performance. It is based on the Zettelkasten system, also called a PKMS, or a "roam-like" editor. It lets you create notes that are deeply linked, without hierarchies. It supports:
- Backlinks
- Support for outlines in each page
- All database files are accessible as text files
- An "overview" generator for the database
- Automated syncronization to a git repository, allowing for multi-device usage of a database

Zek was created by Conrad Barski (The author of "Land of Lisp" as well as other books.) Follow Conrad on twitter at: www.twitter.com/lisperati

# Installing ZEK

To use ZEK, simply put the ZEK executable on the path for your OS. The repository contains three pre-built x86 executable files (`zek_linux`, `zek_macos`, or `zek_windows.exe`) which you should rename to 'zek'. Then, set up a new directory on your PC that will contain your database files. Place the file `help.md` in this directory, for easy access to help information, via the 'h' key. (The help file is just another file in the database.)

# Building ZEK

If you have another OS or CPU, install the zig programming language on your computer (last tested with zig version 0.9.0) and then run `zig build` to generate an executable for your purpose in the `zig-out/bin` directory.

# Running ZEK

Simply execture `zek` from the directory where you want your database files to live. Now follow the youtube video above for basic usage. Hit 'h' for a full list of commands.

# Validating the Database

ZEK will ensure that every linked page has a matching backlink, and will also maintain other database properties. If you ever edit database files by hand, it is therefore recommended that you have ZEK validate the database again to make sure there are no errors in the structure of the database. To do this, run ZEK with the '-validate' flag, i.e. `zek -validate`.

# FAQ

Q: What part of the database is loaded into RAM when the app runs?

A: Only the current page, and the previously-used page (so you can quickly go 'back'). This makes the app extremely fast and light weight. Edits to the current page are saved back to the disk at the moment when another page is visited or when you press [enter] from the prompt (which does nothing aside from saving your work). When a page is saved and it has new links to other pages, the backlinks to those pages are updated on disk at that time as well. However, those other pages are not loaded into RAM to do this.

Q: What is the command for creating a page?

A: To create a page, simply link to the page in square brackets from another page. The only pages that can exist without a link from another page are the calendar pages (which have a date in the title) so you can always just mention on today's calendar day that you are creating a new page, and this automatically creates the page.

Q: Why do the files for date pages have pipe symbols in them?

A: Most OSes don't like file names with slashes. However, when referencing date pages from within zek you can just use reference dates with the usual slashes.

Q: How do I rename a page?

A:You do this by editing the root node of the page outline, which contains the name of the page. To do this, simply perform the edit command `e` without any path (the empty path is the path for the root node).

Q: Why is the command for deleting a page called "yeet"?

A: All commands in ZEK are single letter commands, and I ran out of letters in the alphabet, aside from 'y'.

# License

ZEK is licensed with the Eclipse Public License 1.0 http://opensource.org/licenses/eclipse-1.0.php
