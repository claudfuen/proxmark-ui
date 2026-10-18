# Third-party software in packaged builds

`scripts/make-app.sh` packages these programs and libraries beside ProxmarkUI. They retain their own copyrights and licenses. The script copies the license texts into `ProxmarkUI.app/Contents/Resources/licenses/`.

| Component | Role | License | Source |
| --- | --- | --- | --- |
| [Iceman Proxmark3](https://github.com/RfidResearchGroup/proxmark3) | Client, firmware image, dictionaries, scripts and resources | GPL-3.0-or-later | The checkout supplied through `PM3_SRC`. The reference build uses commit `693ead08038c6ade43833579306e98eb3dd18d8e`. |
| [GNU Readline](https://tiswww.case.edu/php/chet/readline/rltop.html) | Client dynamic library | GPL-3.0-or-later | The Homebrew Readline installation used when building the client. The reference build uses 8.3.3. |
| [LZ4](https://github.com/lz4/lz4) | Client dynamic library | BSD-2-Clause for `lib/` | The Homebrew LZ4 installation used when building the client. The reference build uses 1.10.0. |

The exact linked library set can change with a different Iceman build. Check `otool -L` and the generated app before distributing a binary. A public binary release must provide the corresponding source for GPL-covered binaries alongside the download, including the exact Iceman and Readline sources and any local patches or build scripts. The source repository alone is not a substitute for checking the source obligations of the particular binary being distributed.

ProxmarkUI's Swift source is licensed under GPL-3.0-or-later. The UI launches Iceman as a separate process and communicates through command-line arguments and output; the packaged client remains Iceman's work under its own license.
