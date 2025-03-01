// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-2019 Steve Nygard.

#import "CDMachOFile.h"

#include <mach-o/arch.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

#import "CDMachOFileDataCursor.h"
#import "CDFatFile.h"
#import "CDLoadCommand.h"
#import "CDLCDyldInfo.h"
#import "CDLCDylib.h"
#import "CDLCDynamicSymbolTable.h"
#import "CDLCEncryptionInfo.h"
#import "CDLCRunPath.h"
#import "CDLCSegment.h"
#import "CDLCSymbolTable.h"
#import "CDLCUUID.h"
#import "CDLCVersionMinimum.h"
#import "CDObjectiveC1Processor.h"
#import "CDObjectiveC2Processor.h"
#import "CDSection.h"
#import "CDSymbol.h"
#import "CDRelocationInfo.h"
#import "CDSearchPathState.h"
#import "CDLCSourceVersion.h"
#import "CDLCBuildVersion.h"
#import "CDLCChainedFixups.h"
#import "CDLCExportTRIEData.h"

static NSString *CDMachOFileMagicNumberDescription(uint32_t magic) {
    switch (magic) {
        case MH_MAGIC:    return @"MH_MAGIC";
        case MH_CIGAM:    return @"MH_CIGAM";
        case MH_MAGIC_64: return @"MH_MAGIC_64";
        case MH_CIGAM_64: return @"MH_CIGAM_64";
    }

    return [NSString stringWithFormat:@"0x%08x", magic];
}

@implementation CDMachOFile {
    CDByteOrder _byteOrder;
    
    NSArray *_loadCommands;
    NSArray *_dylibLoadCommands;
    NSArray *_segments;
    CDLCSymbolTable *_symbolTable;
    CDLCDynamicSymbolTable *_dynamicSymbolTable;
    CDLCDyldInfo *_dyldInfo;
    CDLCDylib *_dylibIdentifier;
    CDLCVersionMinimum *_minVersionMacOSX;
    CDLCVersionMinimum *_minVersionIOS;
    CDLCSourceVersion *_sourceVersion;
    CDLCBuildVersion *_buildVersion;
    NSArray *_runPaths;
    NSArray *_runPathCommands;
    NSArray *_dyldEnvironment;
    NSArray *_reExportedDylibs;

    // The parts of struct mach_header_64 pulled out so that our property accessors can be synthesized.
	uint32_t _magic;
	cpu_type_t _cputype;
	cpu_subtype_t _cpusubtype;
	uint32_t _filetype;
	uint32_t _ncmds;
	uint32_t _sizeofcmds;
	uint32_t _flags;
	uint32_t _reserved;
    
    BOOL _uses64BitABI;
}

- (id)init; {
    if ((self = [super init])) {
        _byteOrder = CDByteOrder_LittleEndian;
    }
    
    return self;
}

- (id)initWithData:(NSData *)data filename:(NSString *)filename searchPathState:(CDSearchPathState *)searchPathState; {
    if ((self = [super initWithData:data filename:filename searchPathState:searchPathState])) {
        _byteOrder = CDByteOrder_LittleEndian;
        
        CDDataCursor *cursor = [[CDDataCursor alloc] initWithData:data];
        _magic = [cursor readBigInt32];
        if (_magic == MH_MAGIC || _magic == MH_MAGIC_64) {
            _byteOrder = CDByteOrder_BigEndian;
        } else if (_magic == MH_CIGAM || _magic == MH_CIGAM_64) {
            _byteOrder = CDByteOrder_LittleEndian;
        } else {
            return nil;
        }
        
        _uses64BitABI = (_magic == MH_MAGIC_64) || (_magic == MH_CIGAM_64);
        
        if (_byteOrder == CDByteOrder_LittleEndian) {
            _cputype    = [cursor readLittleInt32];
            _cpusubtype = [cursor readLittleInt32];
            _filetype   = [cursor readLittleInt32];
            _ncmds      = [cursor readLittleInt32];
            _sizeofcmds = [cursor readLittleInt32];
            _flags      = [cursor readLittleInt32];
            if (_uses64BitABI) {
                _reserved = [cursor readLittleInt32];
            }
        } else {
            _cputype    = [cursor readBigInt32];
            _cpusubtype = [cursor readBigInt32];
            _filetype   = [cursor readBigInt32];
            _ncmds      = [cursor readBigInt32];
            _sizeofcmds = [cursor readBigInt32];
            _flags      = [cursor readBigInt32];
            if (_uses64BitABI) {
                _reserved = [cursor readBigInt32];
            }
        }
        
        NSAssert(_uses64BitABI == CDArchUses64BitABI((CDArch){ .cputype = _cputype, .cpusubtype = _cpusubtype }), @"Header magic should match cpu arch", nil);
        
        NSUInteger headerOffset = _uses64BitABI ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
        VerboseLog(@"header offset: %lu", headerOffset);
        CDMachOFileDataCursor *fileCursor = [[CDMachOFileDataCursor alloc] initWithFile:self offset:headerOffset];
        [self _readLoadCommands:fileCursor count:_ncmds];
    }

    return self;
}

- (void)_readLoadCommands:(CDMachOFileDataCursor *)cursor count:(uint32_t)count; {
    NSMutableArray *loadCommands      = [[NSMutableArray alloc] init];
    NSMutableArray *dylibLoadCommands = [[NSMutableArray alloc] init];
    NSMutableArray *segments          = [[NSMutableArray alloc] init];
    NSMutableArray *runPaths          = [[NSMutableArray alloc] init];
    NSMutableArray *runPathCommands   = [[NSMutableArray alloc] init];
    NSMutableArray *dyldEnvironment   = [[NSMutableArray alloc] init];
    NSMutableArray *reExportedDylibs  = [[NSMutableArray alloc] init];
    
    for (uint32_t index = 0; index < count; index++) {
        CDLoadCommand *loadCommand = [CDLoadCommand loadCommandWithDataCursor:cursor];
        if (loadCommand != nil) {
            [loadCommands addObject:loadCommand];

            if (loadCommand.cmd == LC_VERSION_MIN_MACOSX)                        self.minVersionMacOSX = (CDLCVersionMinimum *)loadCommand;
            if (loadCommand.cmd == LC_VERSION_MIN_IPHONEOS)                      self.minVersionIOS = (CDLCVersionMinimum *)loadCommand;
            if (loadCommand.cmd == LC_DYLD_ENVIRONMENT)                          [dyldEnvironment addObject:loadCommand];
            if (loadCommand.cmd == LC_REEXPORT_DYLIB)                            [reExportedDylibs addObject:loadCommand];
            if (loadCommand.cmd == LC_ID_DYLIB)                                  self.dylibIdentifier = (CDLCDylib *)loadCommand;

            if ([loadCommand isKindOfClass:[CDLCSourceVersion class]])           self.sourceVersion = (CDLCSourceVersion *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCBuildVersion class]])       self.buildVersion = (CDLCBuildVersion *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCDylib class]])              [dylibLoadCommands addObject:loadCommand];
            else if ([loadCommand isKindOfClass:[CDLCSegment class]])            [segments addObject:loadCommand];
            else if ([loadCommand isKindOfClass:[CDLCSymbolTable class]])        self.symbolTable = (CDLCSymbolTable *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCDynamicSymbolTable class]]) self.dynamicSymbolTable = (CDLCDynamicSymbolTable *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCDyldInfo class]])           self.dyldInfo = (CDLCDyldInfo *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCExportTRIEData class]])     self.exportsTrie = (CDLCExportTRIEData *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCChainedFixups class]])      self.chainedFixups = (CDLCChainedFixups *)loadCommand;
            else if ([loadCommand isKindOfClass:[CDLCRunPath class]]) {
                [runPaths addObject:[(CDLCRunPath *)loadCommand resolvedRunPath]];
                [runPathCommands addObject:loadCommand];
            }
        }
        InfoLog(@"loadCommand: %@", loadCommand);
    }
    _loadCommands      = [loadCommands copy];
    _dylibLoadCommands = [dylibLoadCommands copy];
    _segments          = [segments copy];
    _runPaths          = [runPaths copy];
    _runPathCommands   = [runPathCommands copy];
    _dyldEnvironment   = [dyldEnvironment copy];
    _reExportedDylibs  = [reExportedDylibs copy];

    for (CDLoadCommand *loadCommand in _loadCommands) {
        [loadCommand machOFileDidReadLoadCommands:self];
    }
    ODLog(@"preferredBaseAddress", [self preferredLoadAddress]);
}

#pragma mark - Debugging

- (NSString *)description; {
    return [NSString stringWithFormat:@"<%@:%p> magic: 0x%08x, cputype: %x, cpusubtype: %x, filetype: %d, ncmds: %ld, sizeofcmds: %d, flags: 0x%x, uses64BitABI? %d, filename: %@, data: %p",
            NSStringFromClass([self class]), self,
            [self magic], [self cputype], [self cpusubtype], [self filetype], [_loadCommands count], 0, [self flags], self.uses64BitABI,
            self.filename, self.data];
}

#pragma mark -

- (CDMachOFile *)machOFileWithArch:(CDArch)arch; {
    if (self.cputype == arch.cputype && self.maskedCPUSubtype == (arch.cpusubtype & ~CPU_SUBTYPE_MASK))
        return self;

    return nil;
}

#pragma mark -

- (cpu_type_t)maskedCPUType; {
    return self.cputype & ~CPU_ARCH_MASK;
}

- (cpu_subtype_t)maskedCPUSubtype; {
    return self.cpusubtype & ~CPU_SUBTYPE_MASK;
}

- (NSUInteger)ptrSize; {
    return self.uses64BitABI ? sizeof(uint64_t) : sizeof(uint32_t);
}
             
// We only have one architecture, so it is by default the best match.  
- (BOOL)bestMatchForArch:(CDArch *)ioArchPtr; {
    if (ioArchPtr != NULL) {
        ioArchPtr->cputype    = self.cputype;
        ioArchPtr->cpusubtype = self.cpusubtype;
    }

    return YES;
}

- (NSString *)filetypeDescription; {
    switch ([self filetype]) {
        case MH_OBJECT:      return @"OBJECT";
        case MH_EXECUTE:     return @"EXECUTE";
        case MH_FVMLIB:      return @"FVMLIB";
        case MH_CORE:        return @"CORE";
        case MH_PRELOAD:     return @"PRELOAD";
        case MH_DYLIB:       return @"DYLIB";
        case MH_DYLINKER:    return @"DYLINKER";
        case MH_BUNDLE:      return @"BUNDLE";
        case MH_DYLIB_STUB:  return @"DYLIB_STUB";
        case MH_DSYM:        return @"DSYM";
        case MH_KEXT_BUNDLE: return @"KEXT_BUNDLE";
        default:
            break;
    }

    return nil;
}

- (NSString *)flagDescription; {
    NSMutableArray *setFlags = [NSMutableArray array];
    uint32_t flags = [self flags];
    if (flags & MH_NOUNDEFS)                [setFlags addObject:@"NOUNDEFS"];
    if (flags & MH_INCRLINK)                [setFlags addObject:@"INCRLINK"];
    if (flags & MH_DYLDLINK)                [setFlags addObject:@"DYLDLINK"];
    if (flags & MH_BINDATLOAD)              [setFlags addObject:@"BINDATLOAD"];
    if (flags & MH_PREBOUND)                [setFlags addObject:@"PREBOUND"];
    if (flags & MH_SPLIT_SEGS)              [setFlags addObject:@"SPLIT_SEGS"];
    if (flags & MH_LAZY_INIT)               [setFlags addObject:@"LAZY_INIT"];
    if (flags & MH_TWOLEVEL)                [setFlags addObject:@"TWOLEVEL"];
    if (flags & MH_FORCE_FLAT)              [setFlags addObject:@"FORCE_FLAT"];
    if (flags & MH_NOMULTIDEFS)             [setFlags addObject:@"NOMULTIDEFS"];
    if (flags & MH_NOFIXPREBINDING)         [setFlags addObject:@"NOFIXPREBINDING"];
    if (flags & MH_PREBINDABLE)             [setFlags addObject:@"PREBINDABLE"];
    if (flags & MH_ALLMODSBOUND)            [setFlags addObject:@"ALLMODSBOUND"];
    if (flags & MH_SUBSECTIONS_VIA_SYMBOLS) [setFlags addObject:@"SUBSECTIONS_VIA_SYMBOLS"];
    if (flags & MH_CANONICAL)               [setFlags addObject:@"CANONICAL"];
    if (flags & MH_WEAK_DEFINES)            [setFlags addObject:@"WEAK_DEFINES"];
    if (flags & MH_BINDS_TO_WEAK)           [setFlags addObject:@"BINDS_TO_WEAK"];
    if (flags & MH_ALLOW_STACK_EXECUTION)   [setFlags addObject:@"ALLOW_STACK_EXECUTION"];
    if (flags & MH_ROOT_SAFE)               [setFlags addObject:@"ROOT_SAFE"];
    if (flags & MH_SETUID_SAFE)             [setFlags addObject:@"SETUID_SAFE"];
    if (flags & MH_NO_REEXPORTED_DYLIBS)    [setFlags addObject:@"NO_REEXPORTED_DYLIBS"];
    if (flags & MH_PIE)                     [setFlags addObject:@"PIE"];

    return [setFlags componentsJoinedByString:@" "];
}

#pragma mark -

- (CDLCSegment *)dataConstSegment {
    // macho objects from iOS 9 appear to store various sections
    // in __DATA_CONST that were previously found in __DATA
    CDLCSegment *seg = [self segmentWithName:@"__DATA_CONST"];

    // Fall back on __DATA if it is not found for earlier behavior
    if (!seg) {
        seg = [self segmentWithName:@"__DATA"];
    }
    return seg;
}

- (CDLCSegment *)segmentWithName:(NSString *)segmentName; {
    for (id loadCommand in _loadCommands) {
        if ([loadCommand isKindOfClass:[CDLCSegment class]] && [[loadCommand name] isEqual:segmentName]) {
            return loadCommand;
        }
    }

    return nil;
}

- (CDLCSegment *)segmentContainingAddress:(NSUInteger)address; {
    //DLog(@"_loadCommands: %@", _loadCommands);
    for (id loadCommand in _loadCommands) {
        //DLog(@"processing load command: %@", loadCommand);
        if ([loadCommand isKindOfClass:[CDLCSegment class]] && [loadCommand containsAddress:address]) {
            //DLog(@"loadCommand: %@ contains address: %lu", loadCommand, address);
            return loadCommand;
        }
    }

    return nil;
}

- (void)showWarning:(NSString *)warning; {
    DLog(@"Warning: %@", warning);
}

/*
 The ony thing macho files are consistently inconsistent about its weird byte ordering
 in the new CHAINED_FIXUP style files sometimes we need the 32 bit equivalent of a value discarding
 'frivolous' 64 bit data to get a particular address properly, and then to 'rebase' it against our preferred load address
 this is part of the 'secret sauce' that made class dump work again
 */

- (uint64_t)fixupBasedAddress:(uint64_t)address {
    if (!self.chainedFixups) return address;
    uint32_t top = address >> 32;
    uint32_t bottom = address & 0xffffffff;
    OILog(@"top", top);
    OILog(@"bottom", bottom);
    OILog(@"new",bottom + self.preferredLoadAddress);
    address = bottom + self.preferredLoadAddress;
    return address;
}

- (NSString *)stringAtAddress:(NSUInteger)address; {
    VLOG_CMD;
    const void *ptr;

    if (address == 0)
        return nil;

    CDLCSegment *segment = [self segmentContainingAddress:address];
    if (segment == nil && self.chainedFixups) { //check for chain fixup rebase
        uint64_t based = [self.chainedFixups rebaseTargetFromAddress:address];
        if (based != 0){
            if ([CDClassDump isVerbose]){
                OILog(@"stringAtAddress: based", based);
            }
            address = based;
            segment = [self segmentContainingAddress:based];
        }
        if (segment == nil) {
            OILog(@"\nstringAtAddress Problem finding address", address);
            address = [self fixupBasedAddress:address];//bottom + self.preferredLoadAddress;
            segment = [self segmentContainingAddress:address];
            if (segment == nil) {
                DLog(@"Error: Cannot find offset for address 0x%08lx in stringAtAddress:", address);
                exit(5);
                return nil;
            }
        }
        
    }

    if ([segment isProtected]) {
        NSData *d2 = [segment decryptedData];
        NSUInteger d2Offset = [segment segmentOffsetForAddress:address];
        if (d2Offset == 0)
            return nil;

        ptr = (uint8_t *)[d2 bytes] + d2Offset;
        return [[NSString alloc] initWithBytes:ptr length:strlen(ptr) encoding:NSASCIIStringEncoding];
    }

    NSUInteger offset = [self dataOffsetForAddress:address];
    if (offset == 0)
        return nil;
    
    // Support small methods referencing selector names in __objc_selrefs.
    CDSection *section = [segment sectionContainingAddress:address];
    if ([[section sectionName] isEqualToString:@"__objc_selrefs"]) {
        const void * reference = [self.data bytes] + offset;
        offset = ([self ptrSize] == 8) ? *((uint64_t *)reference) : *((uint32_t *)reference);
    }
    
    ptr = (uint8_t *)[self.data bytes] + offset;
    NSString *returnString = [[NSString alloc] initWithBytes:ptr length:strlen(ptr) encoding:NSASCIIStringEncoding];
    //VerboseLog(@"stringAtAddress: %@", returnString);
    return returnString;
}

- (NSString *)hackyEntitlements { //TODO: do this properly
    //DLog(@"checking file: %@", self.filename);
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.filename]){
        //DLog(@"file doesnt exist: %@", self.filename);
        return nil;
    }
    NSString *fileContents = [NSString stringWithContentsOfFile:self.filename encoding:NSASCIIStringEncoding error:nil];
    NSUInteger fileLength = [fileContents length];
    if (fileLength == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        fileContents = [NSString stringWithContentsOfFile:self.filename]; //if ascii doesnt work, have to use the deprecated (thankfully not obsolete!) method
#pragma clang diagnostic pop
    }
    fileLength = [fileContents length];
    if (fileLength == 0){
        //DLog(@"file length is 0, failed: %@", self.filename);
        return nil;
    }
    NSScanner *theScanner;
    NSString *text = nil;
    NSString *returnText = nil;
    theScanner = [NSScanner scannerWithString:fileContents];
    while ([theScanner isAtEnd] == NO) {
        [theScanner scanUpToString:@"<?xml" intoString:NULL];
        [theScanner scanUpToString:@"</plist>" intoString:&text];
        text = [text stringByAppendingFormat:@"</plist>"];
        //DLog(@"text: %@", [text dictionaryRepresentation]);
        NSDictionary *dict = [text dictionaryRepresentation];
        if (dict && [dict allKeys].count > 0) {
            if (![[dict allKeys] containsObject:@"CFBundleIdentifier"] && ![[dict allKeys] containsObject:@"cdhashes"]){
                //DLog(@"got im: %@", [[inputFile lastPathComponent] stringByDeletingPathExtension]);
                returnText = text;
                break;
            }
        } else {
            //DLog(@"no entitlements found: %@", self.filename);
        }
    }
    return returnText;
    
}

- (NSString *)entitlements {
    CDSection *section = [[self segmentWithName:@"__TEXT"] sectionWithName:@"__entitlements"];
    if (!section){
        return [self hackyEntitlements];
    }
    NSData *data = [section data];
    NSString *stringData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return stringData;
}

- (NSDictionary *)entitlementsDictionary {
    return [[self entitlements] dictionaryRepresentation];
}

- (NSUInteger)dataOffsetForAddress:(NSUInteger)address; {
    if (address == 0)
        return 0;
    
    InfoLog(@"%s: 0x%08lx (%llu)", _cmds, address, address);
    CDLCSegment *segment = [self segmentContainingAddress:address];
    if (segment == nil && self.chainedFixups) {
        InfoLog(@"%s nil segment", _cmds);
        uint64_t based = [self.chainedFixups rebaseTargetFromAddress:address];
        if (based != 0){
            OILog(@"based", based);
            address = based;
            segment = [self segmentContainingAddress:based];
        } else { // no chained fixup found, maybe we need to discard 'extra' frivolous info and 'rebase' to find the data.
            OILog(@"\nProblem finding address", address);
            address = [self fixupBasedAddress:address];//bottom + self.preferredLoadAddress;
            OILog(@"new value", address);
            segment = [self segmentContainingAddress:address];
        }
        if (segment == nil){
            DLog(@"Error: Cannot find offset for address 0x%08lx in dataOffsetForAddress:", address);
            exit(5);
        }
    }

//    if ([segment isProtected]) {
//        DLog(@"Error: Segment is protected.");
//        exit(5);
//    }
    //[self logInfoForAddress:address];
#if 0
    DLog(@"---------->");
    DLog(@"segment is: %@", segment);
    DLog(@"address: 0x%08x", address);
    DLog(@"CDFile offset:    0x%08x", segment.fileoff);
    DLog(@"file off for address: 0x%08x", [segment fileOffsetForAddress:address]);
    //DLog(@"data offset:      0x%08x", offset + [segment fileOffsetForAddress:address]);
    DLog(@"<----------");
#endif
    return [segment fileOffsetForAddress:address];
}

- (const void *)bytes; {
    return [self.data bytes];
}

- (uint32_t)peekInt32:(NSUInteger)offset; {
    if (_byteOrder == CDByteOrder_LittleEndian)
        return [self peekLittleInt32:offset];

    return [self peekBigInt32:offset];
}

- (uint64_t)peekInt64:(NSUInteger)offset; {
    if (_byteOrder == CDByteOrder_LittleEndian)
        return [self peekLittleInt64:offset];

    return [self peekBigInt64:offset];
}


- (uint32_t)peekBigInt32:(NSUInteger)offset; {
    uint32_t result;

    if (offset + sizeof(result) <= [[self data] length]) {
        result = OSReadBigInt32([[self data] bytes], offset);
    } else {
        [NSException raise:NSRangeException format:@"Trying to read past end in %s", _cmds];
        result = 0;
    }

    return result;
}

- (uint32_t)peekLittleInt32:(NSUInteger)offset; {
    uint32_t result;

    if (offset + sizeof(result) <= [[self data] length]) {
        result = OSReadLittleInt32([[self data] bytes], offset);
    } else {
        [NSException raise:NSRangeException format:@"Trying to read past end in %s", _cmds];
        result = 0;
    }

    return result;
}

- (uint64_t)peekBigInt64:(NSUInteger)offset {
    uint64_t result;

    if (offset + sizeof(result) <= [[self data] length]) {
        result = OSReadBigInt64([[self data] bytes], offset);
    } else {
        [NSException raise:NSRangeException format:@"Trying to read past end in %s", _cmds];
        result = 0;
    }

    return result;
}

- (uint64_t)peekLittleInt64:(NSUInteger)offset {
    uint64_t result;

    if (offset + sizeof(result) <= [[self data] length]) {
        result = OSReadLittleInt64([[self data] bytes], offset);
    } else {
        [NSException raise:NSRangeException format:@"Trying to read past end in %s", _cmds];
        result = 0;
    }

    return result;
}


- (uint64_t)peekPtrAtOffset:(NSUInteger)offset ptrSize:(NSUInteger)ptrSize {
    uint64_t val = 0;
    switch (ptrSize) {
        case sizeof(uint32_t): val = [self peekInt32:offset];
        case sizeof(uint64_t): val = [self peekInt64:offset];
    }
    return val;
}

- (const void *)bytesAtOffset:(NSUInteger)offset; {
    return (uint8_t *)[self.data bytes] + offset;
}

- (NSString *)importBaseName; {
    if ([self filetype] == MH_DYLIB) {
        return CDImportNameForPath(self.filename);
    }

    return nil;
}

#pragma mark -

- (BOOL)isEncrypted; {
    for (CDLoadCommand *loadCommand in _loadCommands) {
        if ([loadCommand isKindOfClass:[CDLCEncryptionInfo class]] && [(CDLCEncryptionInfo *)loadCommand isEncrypted]) {
            return YES;
        }
    }

    return NO;
}

- (BOOL)hasProtectedSegments; {
    for (CDLoadCommand *loadCommand in _loadCommands) {
        if ([loadCommand isKindOfClass:[CDLCSegment class]] && [(CDLCSegment *)loadCommand isProtected])
            return YES;
    }

    return NO;
}

- (BOOL)canDecryptAllSegments; {
    for (CDLoadCommand *loadCommand in _loadCommands) {
        if ([loadCommand isKindOfClass:[CDLCSegment class]] && [(CDLCSegment *)loadCommand canDecrypt] == NO)
            return NO;
    }

    return YES;
}

- (NSString *)loadCommandString:(BOOL)isVerbose; {
    NSMutableString *resultString = [NSMutableString string];
    NSUInteger count = [_loadCommands count];
    for (NSUInteger index = 0; index < count; index++) {
        [resultString appendFormat:@"Load command %lu\n", index];
        CDLoadCommand *loadCommand = _loadCommands[index];
        [loadCommand appendToString:resultString verbose:isVerbose];
        [resultString appendString:@"\n"];
    }

    return resultString;
}

- (NSString *)headerString:(BOOL)isVerbose; {
    NSMutableString *resultString = [NSMutableString string];
    [resultString appendString:@"Mach header\n"];
    [resultString appendString:@"      magic cputype cpusubtype   filetype ncmds sizeofcmds      flags\n"];
    // Grr, %11@ doesn't work.
    if (isVerbose)
        [resultString appendFormat:@"%11@ %7@ %10u   %8@ %5lu %10u %@\n",
                      CDMachOFileMagicNumberDescription([self magic]), [self archName], [self cpusubtype],
                      [self filetypeDescription], [_loadCommands count], 0, [self flagDescription]];
    else
        [resultString appendFormat:@" 0x%08x %7u %10u   %8u %5lu %10u 0x%08x\n",
                      [self magic], [self cputype], [self cpusubtype], [self filetype], [_loadCommands count], 0, [self flags]];
    [resultString appendString:@"\n"];

    return resultString;
}

- (NSUUID *)UUID; {
    for (CDLoadCommand *loadCommand in _loadCommands)
        if ([loadCommand isKindOfClass:[CDLCUUID class]])
            return [(CDLCUUID *)loadCommand UUID];

    return nil;
}

// Must not return nil.
- (NSString *)archName; {
    return CDNameForCPUType([self cputype], [self cpusubtype]);
}

- (void)logInfoForAddress:(NSUInteger)address; {
    if (address != 0) {
        CDLCSegment *segment = [self segmentContainingAddress:address];
        if (segment == nil) {
            DLog(@"No segment contains address: %016lx", address);
        } else {
            DLog(@"Found address %016lx in segment, sections= %@", address, [segment sections]);
            CDSection *section = [segment sectionContainingAddress:address];
            if (section == nil) {
                DLog(@"Found address %016lx in segment %@, but not in a section", address, [segment name]);
            } else {
                DLog(@"Found address %016lx in segment %@, section %@", address, [segment name], [section sectionName]);
            }
        }

        NSString *str = [self stringAtAddress:address];
        DLog(@"      address %016lx as a string: '%@' (length %lu)", address, str, [str length]);
        DLog(@"      address %016lx data offset: %lu", address, [self dataOffsetForAddress:address]);
    }
}

- (NSString *)externalClassNameForAddress:(NSUInteger)address; {
    // Not for NSCFArray (NSMutableArray), NSSimpleAttributeDictionaryEnumerator (NSEnumerator), NSSimpleAttributeDictionary (NSDictionary), etc.
    // It turns out NSMutableArray is in /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation, so...
    // ... it's an undefined symbol, need to look it up.
    CDRelocationInfo *rinfo = [self.dynamicSymbolTable relocationEntryWithOffset:address - [self.symbolTable baseAddress]];
    VerboseLog(@"rinfo: %@", rinfo);
    if (rinfo != nil) {
        CDSymbol *symbol = [[self.symbolTable symbols] objectAtIndex:rinfo.symbolnum];
        VerboseLog(@"symbol: %@", symbol);

        // Now we could use GET_LIBRARY_ORDINAL(), look up the the appropriate mach-o file (being sure to have loaded them even without -r),
        // look up the symbol in that mach-o file, get the address, look up the class based on that address, and finally get the class name
        // from that.

        // Or, we could be lazy and take advantage of the fact that the class name we're after is in the symbol name:
        NSString *str = [symbol name];
        if ([str hasPrefix:ObjCClassSymbolPrefix]) {
            return [str substringFromIndex:[ObjCClassSymbolPrefix length]];
        } else {
            DLog(@"Warning: Unknown prefix on symbol name... %@ (addr %lx)", str, address);
            return str;
        }
    }

    // This is fine, they might really be root objects.  NSObject, NSProxy.
    return nil;
}

- (BOOL)hasRelocationEntryForAddress:(NSUInteger)address; {
    CDRelocationInfo *rinfo = [self.dynamicSymbolTable relocationEntryWithOffset:address - [self.symbolTable baseAddress]];
    VerboseLog(@"%s, rinfo= %@", _cmds, rinfo);
    return rinfo != nil;
}

- (BOOL)hasRelocationEntryForAddress2:(NSUInteger)address; {
    return [self.dyldInfo symbolNameForAddress:address] != nil;
}

- (NSString *)externalClassNameForAddress2:(NSUInteger)address; {
    NSString *str = [self.dyldInfo symbolNameForAddress:address];

    if (str != nil) {
        if ([str hasPrefix:ObjCClassSymbolPrefix]) {
            return [str substringFromIndex:[ObjCClassSymbolPrefix length]];
        } else {
            DLog(@"Warning: Unknown prefix on symbol name... %@ (addr %lx)", str, address);
            return str;
        }
    }

    return nil;
}

- (BOOL)hasObjectiveC1Data; {
    return [self segmentWithName:@"__OBJC"] != nil;
}

- (BOOL)hasObjectiveC2Data; {
    // http://twitter.com/gparker/status/17962955683
    // Oxced: What's the best way to determine the ObjC ABI version of a file?  otool tests if cputype is ARM, but that's not accurate with iOS 4 simulator
    // gparker: @0xced Old ABI has an __OBJC segment. New ABI has a __DATA,__objc_info section.
    // 0xced: @gparker I was hoping for a flag, but that will do it, thanks.
    // 0xced: @gparker Did you mean __DATA,__objc_imageinfo instead of __DATA,__objc_info ?
    // gparker: @0xced Yes, it's __DATA,__objc_imageinfo.
    return [[self dataConstSegment] sectionWithName:@"__objc_imageinfo"] != nil;
}

- (Class)processorClass; {
    if ([self hasObjectiveC2Data])
        return [CDObjectiveC2Processor class];
    
    return [CDObjectiveC1Processor class];
}

- (CDLCDylib *)dylibLoadCommandForLibraryOrdinal:(NSUInteger)libraryOrdinal; {
    if (libraryOrdinal == SELF_LIBRARY_ORDINAL || libraryOrdinal >= MAX_LIBRARY_ORDINAL)
        return nil;
    
    NSArray *loadCommands = _dylibLoadCommands;
    if (_dylibIdentifier != nil) {
        // Remove our own ID (LC_ID_DYLIB) so that we calculate the correct offset
        NSMutableArray *remainingLoadCommands = [loadCommands mutableCopy];
        [remainingLoadCommands removeObject:_dylibIdentifier];
        loadCommands = remainingLoadCommands;
    }
    
    if (libraryOrdinal - 1 < [loadCommands count]) // Ordinals start from 1
        return loadCommands[libraryOrdinal - 1];
    else
        return nil;
}

- (NSString *)architectureNameDescription; {
    return self.archName;
}

- (uint64_t)preferredLoadAddress {
    CDLCSegment *segment = [self segmentWithName:@"__TEXT"];
    //InfoLog(@"Text Segment: %@", segment);
    return segment.vmaddr;
}

@end
