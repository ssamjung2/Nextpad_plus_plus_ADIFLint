#import "Scripts.h"

#import "L10n.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#include "adif_aids.h"
#include "adif_styles.h"

#include <sys/stat.h>

using namespace adifhost;
namespace sc = adif::scripts;

namespace scriptsui {
namespace {

std::string scriptsPath() {
    std::string dir = configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-scripts.adi";
}

struct {
    std::vector<sc::Script> list;
    bool loaded = false;
    time_t mtime = -1;
    off_t size = -1;
} cache;

const adif::styles::OperatingStyle kStyles[] = {adif::styles::OperatingStyle::Social, adif::styles::OperatingStyle::Chasing,
                                               adif::styles::OperatingStyle::Contest, adif::styles::OperatingStyle::Portable};

std::string stylesText(unsigned styles) {
    std::string out;
    for (adif::styles::OperatingStyle s : kStyles)
        if (styles & adif::aids::styleBit(s)) out += (out.empty() ? "" : ", ") + tr(adif::styles::title(s));
    return out.empty() ? tr("none") : out;
}

std::string modesText(unsigned modes) {
    std::string out;
    for (int i = 0; i < sc::kModeGroupCount; ++i)
        if (modes & sc::modeBit((sc::ModeGroup)i)) out += (out.empty() ? "" : ", ") + tr(sc::modeGroupTitle((sc::ModeGroup)i));
    return out.empty() ? tr("none") : out;
}

// ── Edit Scripts ──

struct {
    ADIFToolWindow *w = nil;
    std::vector<sc::Script> list;  // the table's rows
    NSTextField *name = nil, *text = nil;
    NSPopUpButton *when = nil, *insert = nil;
    NSMutableArray<NSButton *> *styles = nil, *modes = nil;
} ed;

sc::Script *chosen() {
    std::vector<NSInteger> sel = [ed.w selectedRows];
    return sel.size() == 1 && (size_t)sel[0] < ed.list.size() ? &ed.list[(size_t)sel[0]] : nullptr;
}

std::vector<std::string> rowOf(const sc::Script &s) {
    return {titleOf(s) + (s.changed ? " " + tr("(changed)") : !s.builtIn ? " " + tr("(yours)") : ""), stylesText(s.styles), modesText(s.modes),
            s.before ? tr("Before a contact") : tr("During a contact"), textOf(s)};
}

void showList(const std::string &select) {
    std::vector<std::vector<std::string>> rows;
    std::vector<std::string> keys;
    std::vector<bool> ticks;
    for (const sc::Script &s : ed.list) {
        rows.push_back(rowOf(s));
        keys.push_back(s.id);
        ticks.push_back(s.shown);
    }
    [ed.w setRows:rows severities:std::vector<int>() keys:keys ticks:ticks keepTicks:NO];
    for (size_t i = 0; i < ed.list.size(); ++i)
        if (!select.empty() && ed.list[i].id == select) [ed.w selectRow:(NSInteger)i];
}

// What the chosen script says now, written out with New QSO's and the station's values.
void preview(NSString *typed) {
    sc::Script *s = chosen();
    if (!s) {
        [ed.w setStatus:T(@"Choose a script to change it, or New Script for one of your own. Tick a script to show it in Operating Aids.") severity:-1];
        return;
    }
    std::vector<std::string> missing;
    std::string written = sc::fill(typed ? ADIFStd(typed) : textOf(*s), scriptValues(), &missing);
    std::string list;
    for (const std::string &m : missing) list += (list.empty() ? "{" : ", {") + m + "}";
    std::string said = trf("Now: {text}", {{"text", written}});
    if (!missing.empty())
        said += "  ·  " + trf("Not known yet: {variables} (New QSO, or the profile's Station Facts)", {{"variables", list}});
    [ed.w setStatus:ADIFString(said) severity:missing.empty() ? -1 : 1];
}

void fillFields() {
    sc::Script *s = chosen();
    BOOL on = s != nullptr;
    for (NSControl *c : @[ ed.name, ed.text, ed.when, ed.insert ]) c.enabled = on;
    for (NSButton *b in ed.styles) b.enabled = on;
    for (NSButton *b in ed.modes) b.enabled = on;
    ed.name.stringValue = s ? ADIFString(titleOf(*s)) : @"";
    ed.text.stringValue = s ? ADIFString(textOf(*s)) : @"";
    [ed.when selectItemAtIndex:s && s->before ? 1 : 0];
    for (size_t i = 0; i < 4; ++i) ed.styles[i].state = s && (s->styles & adif::aids::styleBit(kStyles[i])) ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSUInteger i = 0; i < ed.modes.count; ++i)
        ed.modes[i].state = s && (s->modes & sc::modeBit((sc::ModeGroup)i)) ? NSControlStateValueOn : NSControlStateValueOff;
    preview(nil);
}

// The chosen script as the fields have it now: kept, and its row with it.
void apply() {
    sc::Script *s = chosen();
    if (!s) return;
    std::string name = ADIFStd(ed.name.stringValue), text = ADIFStd(ed.text.stringValue);
    if (name != titleOf(*s)) s->title = name.empty() ? s->title : name;
    if (text != textOf(*s)) s->text = text;
    s->before = ed.when.indexOfSelectedItem == 1;
    unsigned styles = 0, modes = 0;
    for (size_t i = 0; i < 4; ++i)
        if (ed.styles[i].state == NSControlStateValueOn) styles |= adif::aids::styleBit(kStyles[i]);
    for (NSUInteger i = 0; i < ed.modes.count; ++i)
        if (ed.modes[i].state == NSControlStateValueOn) modes |= sc::modeBit((sc::ModeGroup)i);
    s->styles = styles, s->modes = modes;
    if (const sc::Script *b = sc::findBuiltIn(s->id))
        s->changed = s->title != b->title || s->text != b->text || s->styles != b->styles || s->modes != b->modes || s->before != b->before;
    std::string id = s->id;
    save(ed.list);
    ed.list = all();
    showList(id);
    preview(nil);
}

void make() {
    ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Scripts" size:NSMakeSize(1000, 560) headline:NO normal:YES];  // typed into
    ed.w = w;
    [w setTarget:T(@"Operating Aids' scripts: what to say or send, written out with your station's facts and the contact's")];
    ed.name = ADIFTextField(T(@"Its name"), 220);
    ed.name.identifier = @"scripts.name";
    ed.when = ADIFPopup(@[ T(@"During a contact"), T(@"Before a contact (calling CQ)") ]);
    ed.when.identifier = @"scripts.when";
    [w addOptionRow:@[ ADIFLabel(T(@"Name:")), ed.name, ADIFLabel(T(@"When:")), ed.when ]];
    ed.styles = [NSMutableArray array];
    NSMutableArray<NSView *> *styleRow = [NSMutableArray arrayWithObject:ADIFLabel(T(@"Styles:"))];
    for (adif::styles::OperatingStyle st : kStyles) {
        NSButton *b = ADIFCheckbox(ADIFString(tr(adif::styles::title(st))), NO);
        b.identifier = [@"scripts.style." stringByAppendingString:ADIFString(std::string(adif::styles::id(st)))];
        ADIFOnAction(b, ^{ apply(); });
        [ed.styles addObject:b];
        [styleRow addObject:b];
    }
    [w addOptionRow:styleRow];
    ed.modes = [NSMutableArray array];
    NSMutableArray<NSView *> *modeRow = [NSMutableArray arrayWithObject:ADIFLabel(T(@"Modes:"))];
    for (int i = 0; i < sc::kModeGroupCount; ++i) {
        NSButton *b = ADIFCheckbox(ADIFString(tr(sc::modeGroupTitle((sc::ModeGroup)i))), NO);
        b.identifier = [@"scripts.mode." stringByAppendingString:ADIFString(std::string(sc::modeGroupId((sc::ModeGroup)i)))];
        ADIFOnAction(b, ^{ apply(); });
        [ed.modes addObject:b];
        [modeRow addObject:b];
    }
    [w addOptionRow:modeRow];
    ed.text = ADIFTextField(T(@"What to say or send: {CALL} DE {MYCALL}..."), 600);
    ed.text.identifier = @"scripts.text";
    ed.text.cell.wraps = YES;
    ed.text.cell.scrollable = NO;
    ed.text.lineBreakMode = NSLineBreakByWordWrapping;
    [ed.text.heightAnchor constraintEqualToConstant:44].active = YES;
    ed.insert = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    ed.insert.identifier = @"scripts.insert";
    [ed.insert addItemWithTitle:T(@"Insert Variable")];
    ed.insert.menu.autoenablesItems = NO;
    for (const sc::Variable &v : sc::variables()) {
        NSString *token = [NSString stringWithFormat:@"{%s}", v.name];
        NSMenuItem *mi = [ed.insert.menu addItemWithTitle:[NSString stringWithFormat:@"%@  %@", token, T(ADIFString(v.what))] action:nil keyEquivalent:@""];
        ADIFBlockMenuItem(mi, ^{
            // At the caret while it is being typed in, else at its end.
            NSText *editor = ed.text.currentEditor;
            if (editor) {
                [editor insertText:token];
                ed.text.stringValue = editor.string;
            } else {
                ed.text.stringValue = [ed.text.stringValue stringByAppendingString:token];
            }
            apply();
        });
    }
    [w addOptionRow:@[ ADIFLabel(T(@"Script:")), ed.text, ed.insert ]];
    for (NSControl *c : @[ ed.name, ed.text ]) {
        ((NSTextField *)c).cell.sendsActionOnEndEditing = YES;
        ADIFOnAction(c, ^{ apply(); });
    }
    ADIFOnAction(ed.when, ^{ apply(); });
    [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                      object:ed.text
                                                       queue:nil
                                                  usingBlock:^(NSNotification *) { preview(ed.text.stringValue); }];
    [w setColumns:std::vector<ADIFToolColumn>{{"title", "Script", 220}, {"styles", "Styles", 150}, {"modes", "Modes", 150}, {"when", "When", 120},
                                              {"text", "Text", 420}}
        checkboxes:YES
          sortable:NO];
    w.onSelectionChanged = ^{ fillFields(); };
    w.onTicksChanged = ^{
        std::vector<bool> ticks = [ed.w ticked];
        for (size_t i = 0; i < ed.list.size() && i < ticks.size(); ++i) ed.list[i].shown = ticks[i];
        save(ed.list);
    };
    [w addButton:@"New Script" trailing:NO action:^{
        sc::Script s;
        s.id = sc::newId(ed.list);
        s.title = tr("New script");
        s.styles = adif::aids::kSocial | adif::aids::kPortable;
        s.modes = sc::kAllModes;
        s.text = "{CALL} DE {MYCALL} ";
        ed.list.push_back(s);
        save(ed.list);
        ed.list = all();
        showList(s.id);
        fillFields();
        [ed.w.window makeFirstResponder:ed.name];
    }];
    [w addButton:@"Duplicate" trailing:NO action:^{
        sc::Script *s = chosen();
        if (!s) return [ed.w setStatus:T(@"Choose the script to copy.") severity:1];
        sc::Script copy = *s;
        copy.id = sc::newId(ed.list);
        copy.title = titleOf(*s) + " " + tr("copy");
        copy.text = textOf(*s);
        copy.builtIn = copy.changed = copy.words = false;
        ed.list.push_back(copy);
        save(ed.list);
        ed.list = all();
        showList(copy.id);
        fillFields();
    }];
    [w addButton:@"Remove" trailing:NO action:^{
        std::vector<NSInteger> sel = [ed.w selectedRows];
        if (sel.empty()) return [ed.w setStatus:T(@"Choose the scripts to remove.") severity:1];
        std::sort(sel.rbegin(), sel.rend());
        bool builtIn = false;
        for (NSInteger r : sel)
            if ((size_t)r < ed.list.size()) {
                builtIn |= ed.list[(size_t)r].builtIn;
                ed.list.erase(ed.list.begin() + r);
            }
        save(ed.list);
        ed.list = all();
        showList("");
        fillFields();
        std::string said = trp("Removed {n} script.", "Removed {n} scripts.", (long long)sel.size());
        if (builtIn) said += " " + tr("Restore Built-in Scripts brings back the built-in ones.");
        [ed.w setStatus:ADIFString(said) severity:-1];
    }];
    [w addButton:@"Restore Built-in Scripts" trailing:NO action:^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = T(@"Restore the built-in scripts?");
        alert.informativeText = T(@"Each built-in script comes back as it was, shown in Operating Aids; your changes to them are lost. Your own scripts stay.");
        [alert addButtonWithTitle:T(@"Restore")];
        [alert addButtonWithTitle:T(@"Cancel")];
        [alert beginSheetModalForWindow:ed.w.window
                      completionHandler:^(NSModalResponse r) {
                          if (r != NSAlertFirstButtonReturn) return;
                          std::vector<sc::Script> list = sc::builtIns();
                          for (const sc::Script &s : ed.list)
                              if (!s.builtIn) list.push_back(s);
                          ed.list = list;
                          save(ed.list);
                          ed.list = all();
                          showList("");
                          fillFields();
                      }];
    }];
}

}  // namespace

std::vector<sc::Script> all() {
    std::string path = scriptsPath();
    struct stat st{};
    bool there = !path.empty() && stat(path.c_str(), &st) == 0;
    time_t mtime = there ? st.st_mtime : -1;
    off_t size = there ? st.st_size : -1;
    if (!cache.loaded || mtime != cache.mtime || size != cache.size) {
        std::string text;
        if (there)
            if (NSData *data = [NSData dataWithContentsOfFile:ADIFString(path)]) text.assign((const char *)data.bytes, data.length);
        cache.list = sc::load(text);
        cache.loaded = true, cache.mtime = mtime, cache.size = size;
    }
    return cache.list;
}

void save(const std::vector<sc::Script> &list) {
    std::string path = scriptsPath();
    cache.list = sc::load(sc::fileText(list, ADIFLINT_VERSION, ""));  // as it reads back: each built-in's changed mark worked out again
    cache.loaded = true;
    if (!path.empty()) {
        std::string text = sc::fileText(list, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
        [[NSData dataWithBytes:text.data() length:text.size()] writeToFile:ADIFString(path) options:NSDataWritingAtomic error:nil];
        struct stat st{};
        if (stat(path.c_str(), &st) == 0) cache.mtime = st.st_mtime, cache.size = st.st_size;
    }
    scriptsChanged();
}

void setShown(const std::string &id, bool shown) {
    std::vector<sc::Script> list = all();
    for (sc::Script &s : list)
        if (s.id == id) s.shown = shown;
    save(list);
    if (ed.w && ed.w.window.visible) {
        ed.list = all();
        showList("");
    }
}

std::string titleOf(const sc::Script &s) {
    const sc::Script *b = sc::findBuiltIn(s.id);
    return b && s.title == b->title ? tr(s.title.c_str()) : s.title;
}

std::string textOf(const sc::Script &s) {
    const sc::Script *b = sc::findBuiltIn(s.id);
    return b && b->words && s.text == b->text ? tr(s.text.c_str()) : s.text;
}

void cmdEditScripts(const std::string &id) {
    if (!ed.w) make();
    ed.list = all();
    showList(id.empty() && !ed.list.empty() ? ed.list.front().id : id);
    fillFields();
    [ed.w show];
}

}  // namespace scriptsui
