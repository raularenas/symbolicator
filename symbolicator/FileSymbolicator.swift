/*

Created by Tomaz Kragelj on 10.06.2014.
Copyright (c) 2014 Gentle Bytes. All rights reserved.

*/

import Foundation

typealias CrashlogInformation = (name: String, identifier: String, version: String, build: String, architecture: String)

class FileSymbolicator {
	
	func symbolicate(contents: String, archiveHandler: ArchiveHandler) -> String? {
		// Extract all information about the process that crashed. Exit if not possible.
		guard let information = extractProcessInformation(contents) else {
			return nil
		}
		
		// Store parameters for later use.
		self.archiveHandler = archiveHandler
		
		// Prepare array of all lines needed for symbolication.
		let matches = linesToSymbolicate(contents)
		print("Found \(matches.count) lines that need symbolication")
		
		// Symbolicate all matches.
		return symbolicateString(contents, information: information, matches: matches)
	}
	
	private func linesToSymbolicate(contents: NSString) -> [RxMatch] {
		let pattern = "^[0-9]+?\\s+?(.+?)\\s+?(0x[0-9a-fA-F]+?)\\s+?(.+?)$"
		let regex = pattern.toRxWithOptions(.AnchorsMatchLines)
		
		// Find all matches.
		let matches = contents.matchesWithDetails(regex) as! [RxMatch]
		
		// Filter just the ones that have a hex number instead of symbol.
		return matches.filter { match in
			guard let symbolOrAddress = (match.groups[3] as! RxMatchGroup).value else {
				return false
			}
			return symbolOrAddress.hasPrefix("0x")
		}
	}
	
	private func symbolicateString(contents: String, information: CrashlogInformation, matches: [RxMatch]) -> String {
		// Symbolicate all matches. Each entry corresponds to the same match in given array.
		let whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet()
		var result = contents
		for match in matches {
			// Add delimiter above each symbolication when verbose mode is on.
			if settings.printVerbose {
				print("")
			}
			
			// Prepare binary and base address.
			let binary = (match.groups[1] as! RxMatchGroup).value!.stringByTrimmingCharactersInSet(whitespace)
			guard let baseAddress = baseAddressForSymbolication(contents, identifier: binary) else {
				continue
			}
			
			// Prepare dwarf path for this binary.
			guard let dwarfPath = archiveHandler.dwarfPathWithIdentifier(binary, version: information.version, build: information.build) else {
				print("> \(binary): missing DWARF file!")
				continue
			}
			
			// Symbolicate addresses.
			let address = (match.groups[2] as! RxMatchGroup).value!
			guard let symbolizedAddress = symbolicateAddresses(baseAddress, architecture: information.architecture, dwarfPath: dwarfPath, addresses: [address]).first else {
				print("> \(binary) \(address): no symbol found!")
				continue
			}

			// If no symbol is available, ignore.
			let originalString = match.value!
			if (symbolizedAddress.characters.count == 0) {
				print("> \(binary) \(address): no symbol found!")
				continue
			}
			
			// Replace all occurrences within the file.
			let locationInOriginalString = (match.groups[3] as! RxMatchGroup).range.location - match.range.location
			let replacementPrefix = originalString.substringToIndex(originalString.startIndex.advancedBy(locationInOriginalString))
			let replacementString = "\(replacementPrefix)\(symbolizedAddress)"
			result = result.stringByReplacingOccurrencesOfString(originalString, withString: replacementString)
			print("> \(binary) \(address): \(symbolizedAddress)")
		}
		
		return result
	}
	
	private func baseAddresses(contents: String, matches: [RxMatch]) -> [String: (String, [RxMatch])] {
		let ignoredChars = NSCharacterSet.whitespaceAndNewlineCharacterSet()
		
		var result = [String: (String, [RxMatch])]()
		
		// Prepare an array of base addresses per binary.
		for match in matches {
			// Prepare binary and address information.
			let binary = (match.groups[1] as! RxMatchGroup).value.stringByTrimmingCharactersInSet(ignoredChars)
			if binary.characters.count == 0 {
				continue
			}
			
			// If we already matched this pair, reuse it.
			if var existingEntry = result[binary] {
				var matches = existingEntry.1
				matches.append(match)
				existingEntry.1 = matches
				continue
			}
			
			// Otherwise gather it from crash log. Ignore if no match is found.
			guard let baseAddress = baseAddressForSymbolication(contents, identifier: binary) else {
				continue
			}
			
			// Add address to previous addresses so we don't have to repeat.
			result[binary] = (baseAddress, [match])
		}
		
		return result
	}
	
	private func symbolicateAddresses(baseAddress: String, architecture: String, dwarfPath: String, addresses: [String]) -> [String] {
		let arch = architecture.lowercaseString.stringByReplacingOccurrencesOfString("-", withString: "_")
		let stdOutPipe = NSPipe()
		let stdErrPipe = NSPipe()
		let task = NSTask()
		task.launchPath = "/usr/bin/xcrun"
		task.arguments = ["atos", "-arch", arch, "-o", dwarfPath, "-l", baseAddress] + addresses
		task.standardOutput = stdOutPipe
		task.standardError = stdErrPipe
		task.launch()
		task.waitUntilExit()
		
		let translatedData = stdOutPipe.fileHandleForReading.readDataToEndOfFile()
		let translatedString = NSString(data: translatedData, encoding: NSASCIIStringEncoding)!
		
		if settings.printVerbose {
			// Print command line for simpler replication in
			let whitespace = NSCharacterSet.whitespaceCharacterSet()
			let arguments = task.arguments! as [String]
			let cmdline = arguments.reduce("") {
				if let _ = $1.rangeOfCharacterFromSet(whitespace) {
					return "\($0) \"\($1)\""
				}
				return "\($0) \($1)"
			}
			print("\(task.launchPath!) \(cmdline)");
		}
		
		// If there's some error, print it.
		let errorData = stdErrPipe.fileHandleForReading.readDataToEndOfFile()
		if let errorString = NSString(data: errorData, encoding: NSASCIIStringEncoding) where errorString.length > 0 {
			print("\(errorString)")
		}
		
		return translatedString.componentsSeparatedByString("\n") as [String]
	}
	
	private func baseAddressForSymbolication(contents: String, identifier: String) -> String? {
		// Ignore ??? type of identifiers.
		if let _ = identifier.rangeOfCharacterFromSet(NSCharacterSet(charactersInString: "?")) {
			return nil
		}
		
		let pattern = "^\\s+(0x[0-9a-fA-F]+)\\s+-\\s+(0x[0-9a-fA-F]+)\\s+[+]?\(identifier)\\s+"
		if let regex = pattern.toRxWithOptions(.AnchorsMatchLines), let match = regex.firstMatchWithDetails(contents) {
			return (match.groups[1] as! RxMatchGroup).value
		}
		
		print("WARNING: Didn't find starting address for \(identifier)")
		return nil
	}
	
	private func extractProcessInformation(contents: String) -> CrashlogInformation? {
		let optionalProcessMatch = "^Process:\\s+([^\\[]+) \\[[^\\]]+\\]".toRxWithOptions(NSRegularExpressionOptions.AnchorsMatchLines)!.firstMatchWithDetails(contents)
		if (optionalProcessMatch == nil) {
			print("ERROR: Process name is missing!")
			return nil
		}
		
		let optionalIdentifierMatch = "^Identifier:\\s+(.+)$".toRxWithOptions(NSRegularExpressionOptions.AnchorsMatchLines)!.firstMatchWithDetails(contents)
		if (optionalIdentifierMatch == nil) {
			print("ERROR: Process identifier is missing!")
			return nil
		}
		
		let optionalVersionMatch = "^Version:\\s+([^ ]+) \\(([^)]+)\\)$".toRxWithOptions(NSRegularExpressionOptions.AnchorsMatchLines)!.firstMatchWithDetails(contents)
		if (optionalVersionMatch == nil) {
			print("ERROR: Process version and build number is missing!")
			return nil
		}
		
		let optionalArchitectureMatch = "^Code Type:\\s+([^ \\r\\n]+)".toRxWithOptions(NSRegularExpressionOptions.AnchorsMatchLines)!.firstMatchWithDetails(contents);
		if (optionalArchitectureMatch == nil) {
			print("ERROR: Process architecture value is missing!")
			return nil
		}

		let processGroup1 = optionalProcessMatch!.groups[1] as! RxMatchGroup
		let identifierGroup1 = optionalIdentifierMatch!.groups[1] as! RxMatchGroup
		let versionGroup1 = optionalVersionMatch!.groups[1] as! RxMatchGroup
		let versionGroup2 = optionalVersionMatch!.groups[2] as! RxMatchGroup
		let architectureGroup1 = optionalArchitectureMatch!.groups[1] as! RxMatchGroup
		
		let name = processGroup1.value as String
		let identifier = identifierGroup1.value as String
		let version = versionGroup1.value as String
		let build = versionGroup2.value as String
		let architecture = architectureGroup1.value as String
		
		print("Detected \(identifier) \(architecture) [\(name) \(version) (\(build))]")
		return (name, identifier, version, build, architecture)
	}
	
	private var archiveHandler: ArchiveHandler!
}
