/*
 * Copyright (C) 2024 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import ArgumentParser
import Foundation

struct MacCrafter: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A tool to easily build a fully-functional Nextcloud Desktop Client for macOS."
    )

    enum MacCrafterError: Error {
        case failedEnumeration(String)
        case environmentError(String)
    }

    @Argument(help: "Path to the root directory of the Nextcloud Desktop Client git repository.")
    var repoRootDir = "\(FileManager.default.currentDirectoryPath)/../../.."

    @Option(name: [.short, .long], help: "Code signing identity for desktop client and libs.")
    var codeSignIdentity: String?

    @Option(name: [.short, .customLong("buildPath")], help: "Path for build files to be written.")
    var buildPath = "\(FileManager.default.currentDirectoryPath)/build"

    @Option(name: [.long], help: "Brew installation script URL.")
    var brewInstallShUrl = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    @Option(name: [.long], help: "CraftMaster git url.")
    var craftMasterGitUrl = "https://invent.kde.org/packaging/craftmaster.git"

    @Option(name: [.long], help: "Nextcloud Desktop Client craft blueprint git url.")
    var clientBlueprintsGitUrl = "https://github.com/nextcloud/desktop-client-blueprints.git"

    @Option(name: [.long], help: "Nextcloud Desktop Client craft blueprint name.")
    var craftBlueprintName = "nextcloud-client"

    @Option(name: [.long], help: "Build type (e.g. Release, RelWithDebInfo, MinSizeRel, Debug).")
    var buildType = "RelWithDebInfo"

    @Option(name: [.long], help: "Skip craft configuration.")
    var skipCraftConfiguration = false

    @Option(name: [.long], help: "The application's branded name.")
    var appName = "Nextcloud"

    @Option(name: [.long], help: "Build with Sparkle auto-updater.")
    var buildAutoUpdater = true

    @Option(name: [.long], help: "Sparkle download URL.")
    var sparkleDownloadUrl =
        "https://github.com/sparkle-project/Sparkle/releases/download/1.27.3/Sparkle-1.27.3.tar.xz"

    mutating func run() throws {
        print("Configuring build tooling.")

        if codeSignIdentity != nil {
            guard commandExists("codesign") else {
                throw MacCrafterError.environmentError("codesign not found, cannot proceed.")
            }
        }

        try installIfMissing("git", "xcode-select --install")
        try installIfMissing(
            "brew",
            "curl -fsSL \(brewInstallShUrl) | /bin/bash",
            installCommandEnv: ["NONINTERACTIVE": "1"]
        )
        try installIfMissing("inkscape", "brew install inkscape")
        try installIfMissing("python3", "brew install pyenv && pyenv install 3.12.4")

        print("Build tooling configured.")

        let fm = FileManager.default
        let craftMasterDir = "\(buildPath)/craftmaster"
        let craftMasterIni = "\(repoRootDir)/craftmaster.ini"
        let craftMasterPy = "\(craftMasterDir)/CraftMaster.py"
        let craftTarget = "macos-clang-arm64"
        let craftCommand =
            "python3 \(craftMasterPy) --config \(craftMasterIni) --target \(craftTarget) -c"

        if !skipCraftConfiguration {
            print("Configuring KDE Craft.")

            if fm.fileExists(atPath: craftMasterDir) {
                print("KDE Craft is already cloned.")
            } else {
                print("Cloning KDE Craft...")
                shell("git clone --depth=1 \(craftMasterGitUrl) \(craftMasterDir)")
            }

            print("Configuring Nextcloud Desktop Client blueprints for KDE Craft...")
            shell("\(craftCommand) --add-blueprint-repository \(clientBlueprintsGitUrl)")

            print("Crafting KDE Craft...")
            shell("\(craftCommand) craft")

            print("Crafting Nextcloud Desktop Client dependencies...")
            shell("\(craftCommand) --install-deps \(craftBlueprintName)")
        }

        var craftOptions: [String] = []

        if buildAutoUpdater {
            print("Configuring Sparkle auto-updater.")

            let fm = FileManager.default
            guard fm.fileExists(atPath: "\(buildPath)/Sparkle.tar.xz") ||
                  shell("wget \(sparkleDownloadUrl) -O \(buildPath)/Sparkle.tar.xz") == 0
            else {
                throw MacCrafterError.environmentError("Error downloading sparkle.")
            }

            guard fm.fileExists(atPath: "\(buildPath)/Sparkle.framework") ||
                  shell("tar -xvf \(buildPath)/Sparkle.tar.xz -C \(buildPath)") == 0
            else {
                throw MacCrafterError.environmentError("Error unpacking sparkle.")
            }

            craftOptions.append("sparkleLibPath=\(buildPath)/Sparkle.framework")
        }

        print("Crafting Nextcloud Desktop Client...")

        if !craftOptions.isEmpty {
            let craftOptionsArg = craftOptions.map { "--set \"\($0)\"" }
            for option in craftOptions {
                shell("\(craftCommand) \(option) \(craftBlueprintName)")
            }
        }

        shell(
            "\(craftCommand) --src-dir \(repoRootDir) --buildtype \(buildType) -i nextcloud-client"
        )

        guard let codeSignIdentity else {
            print("Crafted Nextcloud Desktop Client. Not codesigned.")
            return
        }

        print("Code-signing Nextcloud Desktop Client libraries and frameworks...")

        let craftBuildDir = "\(buildPath)/\(craftTarget)/build"
        let clientAppDir =
            "\(craftBuildDir)/\(craftBlueprintName)/image-\(buildType)-master/\(appName).app"
        try codesignClientAppBundle(at: clientAppDir, withCodeSignIdentity: codeSignIdentity)

        print("Done!")
    }
}

MacCrafter.main()