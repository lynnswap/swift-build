//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef void (*PluginInitializer)(const void *);

// SwiftPM's in-process engine uses the service override for plugin discovery.
// Its plugins must match the loaded engine, not the Xcode that built this bundle
// or the one selected by xcode-select when the service was installed.
void initializePlugin(const void *manager) {
    @autoreleasepool {
        const char *image = class_getImageName(object_getClass((__bridge id)manager));
        if (image == NULL) {
            fprintf(stderr, "HostPlatformPlugins: cannot locate the plugin manager's image\n");
            return;
        }
        NSURL *bundle = [NSURL fileURLWithPath:@(image)];
        while (![bundle.pathExtension isEqualToString:@"bundle"]) {
            if ([bundle.path isEqualToString:@"/"]) {
                fprintf(stderr, "HostPlatformPlugins: no service bundle contains %s\n", image);
                return;
            }
            bundle = bundle.URLByDeletingLastPathComponent;
        }
        NSURL *plugins = [bundle URLByAppendingPathComponent:@"Contents/PlugIns"];
        NSError *error = nil;
        NSArray<NSURL *> *entries = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:plugins includingPropertiesForKeys:nil options:0 error:&error];
        if (entries == nil) {
            fprintf(stderr, "HostPlatformPlugins: %s\n", error.localizedDescription.UTF8String);
            return;
        }
        NSMutableArray<NSValue *> *initializers = [NSMutableArray array];
        for (NSURL *entry in [entries sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.path compare:b.path];
        }]) {
            if (![entry.pathExtension isEqualToString:@"bundle"]) continue;
            NSString *name = entry.lastPathComponent.stringByDeletingPathExtension;
            NSURL *executable = [entry URLByAppendingPathComponent:
                [@"Contents/MacOS" stringByAppendingPathComponent:name]];
            // Registered Swift extensions outlive this callback, so their images
            // must remain loaded, just as in MutablePluginManager.loadPlugin.
            void *handle = dlopen(executable.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            if (handle == NULL) {
                fprintf(stderr, "HostPlatformPlugins: %s: %s\n", executable.fileSystemRepresentation, dlerror());
                return;
            }
            PluginInitializer initializer = (PluginInitializer)dlsym(handle, "initializePlugin");
            if (initializer == NULL) {
                fprintf(stderr, "HostPlatformPlugins: %s: %s\n", executable.fileSystemRepresentation, dlerror());
                return;
            }
            [initializers addObject:[NSValue valueWithPointer:initializer]];
        }
        // Complete loading before registering anything: a broken dependency
        // must not leave the engine with only some platform extensions.
        for (NSValue *value in initializers) {
            ((PluginInitializer)value.pointerValue)(manager);
        }
    }
}
