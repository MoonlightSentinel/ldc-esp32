#!/bin/rdmd

module setup;

import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

__gshared bool yes;
__gshared string dir;
__gshared string tmpDir;
__gshared string ldcDir;
__gshared string gccDir;

int main(string[] args)
{
	import std.getopt;
	auto helpInformation = getopt(args,
		"y|yes", "Use default answer as input", &yes,
		"d|directory", "Installation directory (defaults to $PWD)", &dir,
	);

	if (helpInformation.helpWanted)
	{
		defaultGetoptPrinter(
			"Some information about the program.",
			helpInformation.options
		);
		return 0;
	}

	if (!dir)
		dir = buildPath(getcwd(), "ldc-xtensa");

	tmpDir = tempDir();
	ldcDir = buildPath(dir, "ldc2");
	gccDir = buildPath(dir, "gcc");

	// if (ask("Install LDC for Xtensa"))
	{
		dir = askExistingPath("Location", dir);

		if (const code = installLDC())
			return code;
	}
	// else
	// {
	// 	dir = askExistingPath("Location", dir, "ldc2/bin/ldc2");
	// }

	if (execute(["xtensa-esp32-elf-gcc", "--version"]).status.ifThrown(1))
	{
		writeln("`xtensa-esp32-elf-gcc` wasn't found in $PATH but is required to link binaries");

		if (ask("Install GCC for Xtensa"))
		{
			gccDir = askExistingPath("Location", gccDir);

			if (const code = installGCC())
				return code;
		}
		else
		{
			gccDir = askExistingPath("Location", gccDir, "xtensa-esp32-elf/bin/xtensa-esp32-elf-gcc");
		}

		patchLDCConf();
	}

	return 0;
}

int installLDC()
{
	version (Windows)
		static assert(false, "TODO");
	version (OSX)
		enum ARTIFACT = "ldc2-xtensa-macos.tar.xz";
	else
		enum ARTIFACT = "ldc2-xtensa-ubuntu.tar.xz";

	static immutable URL = `https://github.com/MoonlightSentinel/ldc-esp32/releases/download/ldc-xtensa-release/` ~ ARTIFACT;

	const artifactPath = buildPath(tmpDir, ARTIFACT);
	if (!exists(artifactPath))
		download(URL, artifactPath);
	mkdirRecurse(ldcDir);
	version (Windows)
		static assert(false, "TODO");
	else
		return run(["tar", "xf", artifactPath, "--directory", ldcDir.dirName ]);
}

int installGCC()
{
	// This is probably wrong in some cases, fix later
	version (Windows)
		enum EXT = `win64.zip`;
	version (OSX)
		enum EXT = `macos.tar.gz`;
	else
		enum EXT = `linux-amd64.tar.gz`;

	enum ARTIFACT = `xtensa-esp32-elf-gcc8_4_0-esp-2021r2-patch3-` ~ EXT;

	// TODO: use latest
	static immutable URL = `https://github.com/espressif/crosstool-NG/releases/download/esp-2021r2-patch3/` ~ ARTIFACT;

	const artifactPath = buildPath(tmpDir, ARTIFACT);
	if (!exists(artifactPath))
		download(URL, artifactPath);
	mkdirRecurse(gccDir);
	version (Windows)
		static assert(false, "TODO");
	else
		return run(["tar", "xf", artifactPath, "--directory", gccDir ]);
}

void patchLDCConf()
{
	const binary = "xtensa-esp32-elf-gcc";
	const path = buildPath(absolutePath(gccDir), "xtensa-esp32-elf", "bin", binary);
	const config = buildPath(ldcDir, "bin", "ldc2.conf");
	const old = readText(config);
	const new_ = old.replace(binary, path);
	assert(old != new_, "Failed to patch ldc2.conf");
	std.file.write(config, new_);
}

string askExistingPath(const string msg, const string default_, const string suffix = null)
{
	while (true)
	{
		const string path = prompt("Location", default_).absolutePath();

		if (suffix)
		{
			if (exists(buildPath(path, suffix)))
				return path;

			stdout.writeln("Expected ", suffix, " inside of the selected directory!");
		}
		else
		{
			if (exists(path))
				return path;
			else
			{
				const parent = dirName(path);
				if (exists(parent))
				{
					writeln(path);
					mkdir(path);
					return path;
				}
			}
			stdout.writeln("The selected directory does not exist!");
		}
	}
}

bool ask(scope string msg)
{
	return prompt(msg, [ "yes", "no" ]) == "yes";
}

string prompt(scope string msg, scope string[] options...)
{
	stderr.flush();

	while (true)
	{
		stdout.writef!`%-s (%-(%s / %)): `(msg, options);
		stdout.flush();

		if (yes)
		{
			stdout.writeln();
			return options[0];
		}

		const input = stdin.readln().strip();

		if (input == "")
			return options[0];

		if (options.canFind(input))
			return input;

		stdout.write("Invalid input! ");
	}
}

int run(scope const char[][] command)
{
	stdout.writefln!`%-(%s %)`(command);
	try
		return spawnProcess(command).wait();
	catch (Exception e)
	{
		writeln(e.msg);
		return 1;
	}
}

void download(const string url, const string path)
{
	static import std.net.curl;
	writeln("Downloading ", url, " to ", path);
	std.net.curl.download(url, path);
}
