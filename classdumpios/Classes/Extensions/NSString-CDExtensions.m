// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-2019 Steve Nygard.

#import "NSString-CDExtensions.h"
#import "NSData-CDExtensions.h"

@implementation NSMutableDictionary (CDExtensions)

- (NSString *)stringRepresentation {
    NSString *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *xmlData = [NSPropertyListSerialization dataFromPropertyList:self format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    NSString *s=[[NSString alloc] initWithData:xmlData encoding: NSUTF8StringEncoding];
    return s;
}

@end

@implementation NSDictionary (CDExtensions)

- (NSString *)stringRepresentation {
    NSString *error = nil;
    NSData *xmlData = [NSPropertyListSerialization dataFromPropertyList:self format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    NSString *s=[[NSString alloc] initWithData:xmlData encoding: NSUTF8StringEncoding];
    return s;
}

@end

@implementation NSString (CDExtensions)

- (id)dictionaryRepresentation {
    NSString *error = nil;
    NSPropertyListFormat format;
    NSData *theData = [self dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];

    id theDict = [NSPropertyListSerialization propertyListFromData:theData
                                                  mutabilityOption:NSPropertyListMutableContainersAndLeaves
                                                            format:&format
                                                  errorDescription:&error];
#pragma clang diagnostic pop
    return theDict;
}

+ (NSString *)stringWithFileSystemRepresentation:(const char *)str;
{
    // 2004-01-16: I'm don't understand why we need to pass in the length.
    return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:str length:strlen(str)];
}

+ (NSString *)spacesIndentedToLevel:(NSUInteger)level;
{
    return [self spacesIndentedToLevel:level spacesPerLevel:4];
}

+ (NSString *)spacesIndentedToLevel:(NSUInteger)level spacesPerLevel:(NSUInteger)spacesPerLevel;
{
    NSString *spaces = @"                                        ";

    NSParameterAssert(spacesPerLevel <= [spaces length]);
    NSString *levelSpaces = [spaces substringToIndex:spacesPerLevel];

    NSMutableString *str = [NSMutableString string];
    for (NSUInteger l = 0; l < level; l++)
        [str appendString:levelSpaces];

    return str;
}

+ (NSString *)stringWithUnichar:(unichar)character;
{
    return [NSString stringWithCharacters:&character length:1];
}

- (BOOL)isFirstLetterUppercase;
{
    NSRange letterRange = [self rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
    if (letterRange.length == 0)
        return NO;

    return [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[self characterAtIndex:letterRange.location]];
}

- (void)print;
{
    NSData *data = [self dataUsingEncoding:NSUTF8StringEncoding];
    [(NSFileHandle *)[NSFileHandle fileHandleWithStandardOutput] writeData:data];
}

- (NSString *)executablePathForFilename;
{
    NSString *path;

    // I give up, all the methods dealing with paths seem to resolve symlinks with a vengence.
    NSBundle *bundle = [NSBundle bundleWithPath:self];
    if (bundle != nil) {
        if ([bundle executablePath] == nil)
            return nil;

        path = [[[bundle executablePath] stringByResolvingSymlinksInPath] stringByStandardizingPath];
    } else {
        path = [[self stringByResolvingSymlinksInPath] stringByStandardizingPath];
    }

    return path;
}

- (NSString *)SHA1DigestString;
{
    return [[[[self decomposedStringWithCanonicalMapping] dataUsingEncoding:NSUTF8StringEncoding] SHA1Digest] hexString];
}

- (BOOL)hasUnderscoreCapitalPrefix;
{
    if ([self length] < 2)
        return NO;

    return [self hasPrefix:@"_"] && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[self characterAtIndex:1]];
}

- (NSString *)capitalizeFirstCharacter;
{
    if ([self length] < 2)
        return [self capitalizedString];

    return [NSString stringWithFormat:@"%@%@", [[self substringToIndex:1] capitalizedString], [self substringFromIndex:1]];
}

@end

@implementation NSMutableString (CDExtensions)

- (void)appendSpacesIndentedToLevel:(NSUInteger)level;
{
    [self appendSpacesIndentedToLevel:level spacesPerLevel:4];
}

- (void)appendSpacesIndentedToLevel:(NSUInteger)level spacesPerLevel:(NSUInteger)spacesPerLevel;
{
    NSString *spaces = @"                                        ";

    NSParameterAssert(spacesPerLevel <= [spaces length]);
    NSString *levelSpaces = [spaces substringToIndex:spacesPerLevel];

    for (NSUInteger l = 0; l < level; l++)
        [self appendString:levelSpaces];
}

@end
