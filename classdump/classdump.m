//
//  classdump.m
//  classdump
//
//  Created by Kevin Bradley on 6/21/22.
//

#import "classdump.h"

@implementation classdump

+ (id)sharedInstance {
    
    static dispatch_once_t onceToken;
    static classdump *shared;
    if (!shared){
        dispatch_once(&onceToken, ^{
            shared = [classdump new];
        });
    }
    return shared;
}

- (CDClassDump *)classDumpInstanceFromFile:(NSString *)file {
    CDClassDump *classDump = [[CDClassDump alloc] init];
    NSString *executablePath = [file executablePathForFilename];
    if (executablePath){
        classDump.searchPathState.executablePath = executablePath;
        CDFile *file = [CDFile fileWithContentsOfFile:executablePath searchPathState:classDump.searchPathState];
        if (file == nil) {
            NSFileManager *defaultManager = [NSFileManager defaultManager];
            
            if ([defaultManager fileExistsAtPath:executablePath]) {
                if ([defaultManager isReadableFileAtPath:executablePath]) {
                    fprintf(stderr, "class-dump: Input file (%s) is neither a Mach-O file nor a fat archive.\n", [executablePath UTF8String]);
                } else {
                    fprintf(stderr, "class-dump: Input file (%s) is not readable (check read permissions).\n", [executablePath UTF8String]);
                }
            } else {
                fprintf(stderr, "class-dump: Input file (%s) does not exist.\n", [executablePath UTF8String]);
            }

            return nil;
        }
        
        //got this far file is not nil
        CDArch targetArch;
        if ([file bestMatchForLocalArch:&targetArch] == NO) {
            fprintf(stderr, "Error: Couldn't get local architecture\n");
            return nil;
        }
        //DLog(@"No arch specified, best match for local arch is: (%08x, %08x)", targetArch.cputype, targetArch.cpusubtype);
        classDump.targetArch = targetArch;
        classDump.searchPathState.executablePath = [executablePath stringByDeletingLastPathComponent];
        NSError *error;
        if (![classDump loadFile:file error:&error]) {
            fprintf(stderr, "Error: %s\n", [[error localizedFailureReason] UTF8String]);
            return nil;
        }
        return classDump;
    }
    return nil;
}

- (NSInteger)performClassDumpOnFile:(NSString *)file toFolder:(NSString *)outputPath {
    
    CDClassDump *classDump = [self classDumpInstanceFromFile:file];
    if (!classDump){
        DLog(@"couldnt create class dump instance for file: %@", file);
        return -1;
    }
    classDump.shouldShowIvarOffsets = true; // -a
    classDump.shouldShowMethodAddresses = true; // -A
    [classDump processObjectiveCData];
    [classDump registerTypes];
    CDMultiFileVisitor *multiFileVisitor = [[CDMultiFileVisitor alloc] init]; // -H
    multiFileVisitor.classDump = classDump;
    classDump.typeController.delegate = multiFileVisitor;
    multiFileVisitor.outputPath = outputPath;
    [classDump recursivelyVisit:multiFileVisitor];
    return 0;
}

- (NSInteger)oldperformClassDumpOnFile:(NSString *)file toFolder:(NSString *)outputPath {
    
    CDClassDump *classDump = [[CDClassDump alloc] init];
    classDump.shouldShowIvarOffsets = true; // -a
    classDump.shouldShowMethodAddresses = true; // -A
    //classDump.shouldSortClassesByInheritance = true; // -I
    NSString *executablePath = [file executablePathForFilename];
    if (executablePath){
        classDump.searchPathState.executablePath = executablePath;
        CDFile *file = [CDFile fileWithContentsOfFile:executablePath searchPathState:classDump.searchPathState];
        if (file == nil) {
            NSFileManager *defaultManager = [NSFileManager defaultManager];
            
            if ([defaultManager fileExistsAtPath:executablePath]) {
                if ([defaultManager isReadableFileAtPath:executablePath]) {
                    fprintf(stderr, "class-dump: Input file (%s) is neither a Mach-O file nor a fat archive.\n", [executablePath UTF8String]);
                } else {
                    fprintf(stderr, "class-dump: Input file (%s) is not readable (check read permissions).\n", [executablePath UTF8String]);
                }
            } else {
                fprintf(stderr, "class-dump: Input file (%s) does not exist.\n", [executablePath UTF8String]);
            }

            return 1;
        }
        
        //got this far file is not nil
        CDArch targetArch;
        if ([file bestMatchForLocalArch:&targetArch] == NO) {
            fprintf(stderr, "Error: Couldn't get local architecture\n");
            return 1;
        }
        //DLog(@"No arch specified, best match for local arch is: (%08x, %08x)", targetArch.cputype, targetArch.cpusubtype);
        classDump.targetArch = targetArch;
        classDump.searchPathState.executablePath = [executablePath stringByDeletingLastPathComponent];
        
        NSError *error;
        if (![classDump loadFile:file error:&error]) {
            fprintf(stderr, "Error: %s\n", [[error localizedFailureReason] UTF8String]);
            return 1;
        } else {
            [classDump processObjectiveCData];
            [classDump registerTypes];
            CDMultiFileVisitor *multiFileVisitor = [[CDMultiFileVisitor alloc] init]; // -H
            multiFileVisitor.classDump = classDump;
            classDump.typeController.delegate = multiFileVisitor;
            multiFileVisitor.outputPath = outputPath;
            [classDump recursivelyVisit:multiFileVisitor];
        }
    } else {
        fprintf(stderr, "no exe path found for: %s\n", [file UTF8String]);
        return -1;
    }
    return 0;
}

@end
