
#import "CompilationSettingsWindowController.h"

#import "PluginManager.h"
#import "Compiler.h"
#import "RubyVersion.h"
#import "ToolOptions.h"
#import "CompilationOptions.h"
#import "FileCompilationOptions.h"
#import "Project.h"

#import "UIBuilder.h"
#import "sglib.h"
#include "kvec.h"
#include "stringutil.h"
#include "jansson.h"



typedef enum {
    compilation_settings_tab_options,
    compilation_settings_tab_paths,
} compilation_settings_tab_t;

typedef enum {
    output_paths_table_column_enable,
    output_paths_table_column_source,
    output_paths_table_column_output,
} output_paths_table_column_t;

const char *output_paths_table_column_ids[] = { "on", "source", "output" };

typedef struct compilable_file_t {
    char *source_path;
    Compiler *compiler;
    FileCompilationOptions *file_options;
    struct compilable_file_t *next;
} compilable_file_t;

void compilable_file_free(compilable_file_t *file) {
  free(file->source_path);
  [file->file_options release];
  free(file);
}



@interface CompilationSettingsWindowController () <NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate> {
    NSArray               *_compilerOptions;
    BOOL                   _populatingRubyVersions;
    NSArray               *_rubyVersions;

    CGFloat                _compilerSettingsWindowHeight;
    CGFloat                _outputPathsWindowHeight;

    kvec_t(compilable_file_t *) _fileList;
}

- (void)populateToolVersions;
- (void)updateOutputPathsTabData;
- (void)resizeWindowForTab:(NSTabViewItem *)item animated:(BOOL)animated;
- (void)didDetectChange;

@end


EVENTBUS_OBJC_HANDLER(CompilationSettingsWindowController, project_fs_change_event, didDetectChange)

@implementation CompilationSettingsWindowController

@synthesize nodeVersionsPopUpButton = _nodeVersionsPopUpButton;
@synthesize rubyVersionsPopUpButton = _rubyVersionsPopUpButton;
@synthesize tabView = _tabView;
@synthesize compilerSettingsTabView = _compilerSettingsTabView;
@synthesize pathTableView = _pathTableView;
@synthesize chooseFolderButton = _chooseFolderButton;

- (void)dealloc {
    [_compilerOptions release], _compilerOptions = nil;
    [_rubyVersions release], _rubyVersions = nil;
    kv_each(compilable_file_t *, _fileList, file, compilable_file_free(file));
    kv_init(_fileList);
    [super dealloc];
}

- (void)windowDidLoad {
    _outputPathsWindowHeight = _tabView.frame.size.height;
    [_project requestMonitoring:YES forKey:@"compilationSettings"];
    EVENTBUS_OBJC_SUBSCRIBE(CompilationSettingsWindowController, project_fs_change_event);
    [super windowDidLoad];
}

- (IBAction)dismiss:(id)sender {
    [_project requestMonitoring:NO forKey:@"compilationSettings"];
    EVENTBUS_OBJC_UNSUBSCRIBE(CompilationSettingsWindowController, project_fs_change_event);
    [super dismiss:sender];
}



#pragma mark - Actions

- (IBAction)showHelp:(id)sender {
    TenderShowArticle(@"features/compilation");
}


#pragma mark - Compiler settings

- (void)renderOptions:(NSArray *)options forCompiler:(Compiler *)compiler withBuilder:(UIBuilder *)builder isFirst:(BOOL *)isFirstCompiler {
    if (!*isFirstCompiler)
        [builder addVisualBreak];
    *isFirstCompiler = NO;

    BOOL isFirst = YES;
    for (ToolOption *option in options) {
        [option renderWithBuilder:builder];

        if (isFirst && !builder.labelAdded) {
            [builder addLabel:[NSString stringWithFormat:@"%@:", compiler.name]];
        }
        isFirst = NO;
    }

    if (isFirst) {
        [builder addRightLabel:@"No options for this compiler"];
        [builder addLabel:[NSString stringWithFormat:@"%@:", compiler.name]];
    }
}


#pragma mark - Model sync

- (void)renderCompilerOptions {
    NSArray *compilers = _project.compilersInUse;
    NSMutableArray *allOptions = [[NSMutableArray alloc] init];

    UIBuilder *builder = [[UIBuilder alloc] initWithView:_compilerSettingsTabView];
    CGFloat heightDelta = [builder buildUIWithTopInset:8 bottomInset:12 block:^{
        if (compilers.count > 0) {
            BOOL isFirst = YES;
            for (Compiler *compiler in compilers) {
                NSArray *options = [compiler optionsForProject:_project];

                EnabledToolOption *enabledOption = [[[EnabledToolOption alloc] initWithCompiler:compiler project:_project optionInfo:nil] autorelease];
                options = [[NSArray arrayWithObject:enabledOption] arrayByAddingObjectsFromArray:options];

                [self renderOptions:options forCompiler:compiler withBuilder:builder isFirst:&isFirst];
                [allOptions addObjectsFromArray:options];
            }
        } else {
            [builder addFullWidthLabel:@"No compilable files found in this folder."];
        }
    }];
    [builder release];

    _compilerSettingsWindowHeight = _outputPathsWindowHeight + heightDelta;

    _compilerOptions = [[NSArray alloc] initWithArray:allOptions];
    [allOptions release];
}

- (void)render {
    [self renderCompilerOptions];
    [self populateToolVersions];
    [self updateOutputPathsTabData];
    NSString *tabIdentifier = [[NSUserDefaults standardUserDefaults] objectForKey:@"compilationOptionsTab"];
    if (tabIdentifier) {
        [_tabView selectTabViewItemWithIdentifier:tabIdentifier];
    }

    [self resizeWindowForTab:[_tabView selectedTabViewItem] animated:NO];
}

- (void)save {
    for (ToolOption *option in _compilerOptions) {
        [option save];
    }
}


#pragma mark - Tool Versions

- (void)populateRubyVersions {
    if (_populatingRubyVersions)
        return;
    _populatingRubyVersions = YES;

    if (_rubyVersionsPopUpButton.tag != 0x101) {
        _rubyVersionsPopUpButton.tag = 0x101;
        [_rubyVersionsPopUpButton removeAllItems];
        [_rubyVersionsPopUpButton addItemWithTitle:@"Loading…"];
        [_rubyVersionsPopUpButton setEnabled:NO];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        NSArray *version = [[RubyVersion availableRubyVersions] retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            [_rubyVersions release], _rubyVersions = version;

            // find the selected item
            NSInteger selectedIndex = -1, index = 0;
            for (RubyVersion *version in _rubyVersions) {
                if ([_project.rubyVersionIdentifier isEqualToString:version.identifier])
                    selectedIndex = index;
                ++index;
            }

            // add if not found
            if (selectedIndex < 0) {
                RubyVersion *version = [RubyVersion rubyVersionWithIdentifier:_project.rubyVersionIdentifier];
                [_rubyVersions autorelease];
                _rubyVersions = [[[NSArray arrayWithObject:version] arrayByAddingObjectsFromArray:_rubyVersions] retain];
                selectedIndex = 0;
            }

            // might involve invocation of Rubies, so do this before removeAllItems to avoid flicker
            NSArray *titles = [_rubyVersions valueForKeyPath:@"displayTitle"];

            [_rubyVersionsPopUpButton removeAllItems];
            [_rubyVersionsPopUpButton addItemsWithTitles:titles];
            [_rubyVersionsPopUpButton setEnabled:YES];
            [_rubyVersionsPopUpButton selectItemAtIndex:selectedIndex];

            _populatingRubyVersions = NO;
        });
    });
}

- (void)populateToolVersions {
    [self populateRubyVersions];
}

- (IBAction)nodeVersionsPopUpValueDidChange:(id)sender {
}

- (IBAction)rubyVersionsPopUpValueDidChange:(id)sender {
    NSInteger index = [_rubyVersionsPopUpButton indexOfSelectedItem];
    if (index < 0)
        return;
    RubyVersion *version = [_rubyVersions objectAtIndex:index];
    _project.rubyVersionIdentifier = version.identifier;
}


#pragma mark - Tabs

- (void)tabView:(NSTabView *)tabView willSelectTabViewItem:(NSTabViewItem *)tabViewItem {
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    [[NSUserDefaults standardUserDefaults] setObject:tabViewItem.identifier forKey:@"compilationOptionsTab"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self resizeWindowForTab:tabViewItem animated:YES];
}

- (compilation_settings_tab_t)enumForItem:(NSTabViewItem *)item {
    return ([[item identifier] isEqualToString:@"options"] ? compilation_settings_tab_options : compilation_settings_tab_paths);
}

- (compilation_settings_tab_t)currentTab {
    return [self enumForItem:_tabView.selectedTabViewItem];
}

- (void)resizeWindowForTab:(NSTabViewItem *)item animated:(BOOL)animated {
    CGFloat desiredHeight = ([self enumForItem:item] == compilation_settings_tab_options ? _compilerSettingsWindowHeight : _outputPathsWindowHeight);

    NSRect rect = self.window.frame;

    BOOL heightSet = NO;
    if ([self currentTab] == compilation_settings_tab_paths) {
        CGFloat height = [[NSUserDefaults standardUserDefaults] floatForKey:@"compilationOptions.height.paths"];
        if (height > 0.0) {
            rect.size.height = height;
            heightSet = YES;
        }
    }
    if (!heightSet) {
        rect.size.height += (desiredHeight - _tabView.frame.size.height);
    }

    CGFloat width = [[NSUserDefaults standardUserDefaults] floatForKey:@"compilationOptions.width"];
    if (width > 0.0) {
        rect.size.width = width;
    }

    [self.window setFrame:rect display:YES animate:YES];
}

- (void)didDetectChange {
    [self updateOutputPathsTabData];
    [_pathTableView reloadData];
}



#pragma mark - Output Paths Tab

- (void)updateOutputPathsTabData {
    kv_each(compilable_file_t *, _fileList, file, compilable_file_free(file));
    kv_init(_fileList);

    FSTree *tree = _project.tree;
    for (Compiler *compiler in _project.compilersInUse) {
        CompilationOptions *options = [_project optionsForCompiler:compiler create:YES];

        for (NSString *path in [compiler pathsOfSourceFilesInTree:tree]) {
            FileCompilationOptions *fileOptions = [_project optionsForFileAtPath
              :path in:options];

            compilable_file_t *file = malloc(sizeof(compilable_file_t));
            file->next = NULL;
            file->compiler = compiler;
            file->source_path = strdup([path UTF8String]);
            file->file_options = [fileOptions retain];
            kv_push(compilable_file_t *, _fileList, file);
        }

    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return kv_size(_fileList);
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    compilable_file_t *file = kv_A(_fileList, row);
    output_paths_table_column_t column = str_static_array_index(output_paths_table_column_ids, [[tableColumn identifier] UTF8String]);
    BOOL imported = [_project isFileImported:[NSString stringWithUTF8String:file->source_path]];
    if (column == output_paths_table_column_enable) {
        if (imported)
            return [NSNumber numberWithBool:NO];
        return [NSNumber numberWithBool:file->file_options.enabled];
    } else if (column == output_paths_table_column_source) {
        return [NSString stringWithUTF8String:file->source_path];
    } else if (column == output_paths_table_column_output) {
        if (imported)
            return @"(imported)";
        return file->file_options.destinationDirectoryForDisplay;
    } else {
        return nil;
    }
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    compilable_file_t *file = kv_A(_fileList, row);
    output_paths_table_column_t column = str_static_array_index(output_paths_table_column_ids, [[tableColumn identifier] UTF8String]);
    if (column == output_paths_table_column_enable) {
        file->file_options.enabled = [object boolValue];
    } else if (column == output_paths_table_column_source) {
    } else if (column == output_paths_table_column_output) {
        file->file_options.destinationDirectory = [object stringByExpandingTildeInPath];
    } else {
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    compilable_file_t *file = kv_A(_fileList, row);
    output_paths_table_column_t column = str_static_array_index(output_paths_table_column_ids, [[tableColumn identifier] UTF8String]);
    if (column == output_paths_table_column_enable || column == output_paths_table_column_output) {
        BOOL imported = [_project isFileImported:[NSString stringWithUTF8String:file->source_path]];
        return !imported;
    }
    return YES;
}


- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    compilable_file_t *file = kv_A(_fileList, row);
    output_paths_table_column_t column = str_static_array_index(output_paths_table_column_ids, [[tableColumn identifier] UTF8String]);
    BOOL imported = [_project isFileImported:[NSString stringWithUTF8String:file->source_path]];
    if (column == output_paths_table_column_enable) {
        NSButtonCell *theCell = cell;
        [theCell setEnabled:!imported];
    } else if (column == output_paths_table_column_output) {
        NSTextFieldCell *theCell = cell;
        [theCell setEnabled:!imported];
    }
}

#pragma mark -

- (IBAction)chooseOutputDirectory:(id)sender {
    if (kv_size(_fileList) == 0) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"No files yet"];
        [alert setInformativeText:@"Before configuring an output directory, please create some source files first."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return;
    }

    NSIndexSet *indexSet = [_pathTableView selectedRowIndexes];
    NSMutableArray *selection = [NSMutableArray array];
    for (NSUInteger currentIndex = [indexSet firstIndex]; currentIndex != NSNotFound; currentIndex = [indexSet indexGreaterThanIndex:currentIndex]) {
        compilable_file_t *file = kv_A(_fileList, currentIndex);
        [selection addObject:file->file_options];
    }

    NSString *initialPath = _project.path;
    NSString *common;
    if ([selection count] == 0) {
        kv_each(compilable_file_t *, _fileList, file, [selection addObject:file->file_options]);

        NSString *common = [FileCompilationOptions commonOutputDirectoryFor:selection];
        if ([common isEqualToString:@"__NONE_SET__"]) {
            // do nothing
        } else if (common != nil) {
            initialPath = [_project.path stringByAppendingPathComponent:common];
        } else {
            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setMessageText:@"Change all files?"];
            [alert setInformativeText:@"Files are currently configured with different output directories. Proceeding will set the SAME output directory for ALL files.\n\nYou can configure individual files by selecting them first."];
            [[alert addButtonWithTitle:@"Proceed"] setKeyEquivalent:@""];
            [alert addButtonWithTitle:@"Cancel"];
            if ([alert runModal] != NSAlertFirstButtonReturn) {
                return;
            }
        }
    } else if ([selection count] > 1) {
        NSString *common = [FileCompilationOptions commonOutputDirectoryFor:selection];
        if ([common isEqualToString:@"__NONE_SET__"]) {
            // do nothing
        } else if (common != nil) {
            initialPath = [_project.path stringByAppendingPathComponent:common];
        } else {
            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setMessageText:@"Change all selected files?"];
            [alert setInformativeText:@"Selected files are currently configured with different output directories. Proceeding will set the same output directory for all selected files."];
            [[alert addButtonWithTitle:@"Proceed"] setKeyEquivalent:@""];
            [alert addButtonWithTitle:@"Cancel"];
            if ([alert runModal] != NSAlertFirstButtonReturn) {
                return;
            }
        }
    } else {
        common = ((FileCompilationOptions *)[selection objectAtIndex:0]).destinationDirectory;
        if (common != nil) {
            initialPath = [_project.path stringByAppendingPathComponent:common];
        }
    }

    NSOpenPanel *openPanel;
    NSInteger result;
retry:
    openPanel = [NSOpenPanel openPanel];
    [openPanel setCanChooseDirectories:YES];
    [openPanel setCanCreateDirectories:YES];
    [openPanel setPrompt:@"Choose folder"];
    [openPanel setCanChooseFiles:NO];
    [openPanel setDirectoryURL:[NSURL fileURLWithPath:initialPath isDirectory:YES]];
    result = [openPanel runModal];
    if (result == NSFileHandlingPanelOKButton) {
        NSURL *url = [openPanel URL];
        NSString *absolutePath = [url path];
        NSString *relativePath = [_project relativePathForPath:absolutePath];
        if (relativePath == nil) {
            if ([[NSAlert alertWithMessageText:@"Subdirectory required" defaultButton:@"Retry" alternateButton:@"Cancel" otherButton:nil informativeTextWithFormat:@"Sorry, the path you have chosen in not a subdirectory of the project.\n\nChosen path:\n%@\n\nMust be a subdirectory of:\n%@", [absolutePath stringByAbbreviatingWithTildeInPath], [_project.path stringByAbbreviatingWithTildeInPath]] runModal] == NSAlertDefaultReturn) {
                goto retry;
            }
            return;
        }
        for (FileCompilationOptions *options in selection) {
            options.destinationDirectory = relativePath;
        }
    }
}


#pragma mark - Settings Restore

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object == self.window) {
        NSSize size = self.window.frame.size;
        if ([self currentTab] == compilation_settings_tab_paths) {
            [[NSUserDefaults standardUserDefaults] setFloat:size.height forKey:@"compilationOptions.height.paths"];
        }
        [[NSUserDefaults standardUserDefaults] setFloat:size.width forKey:@"compilationOptions.width"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}


@end
