-- hbDoc: pulls /// documentation out of C++ source and renders it as HTML.
--
-- Usage:
--   lua hbDoc.lua --test        (reads test/src/*.cpp, writes test/docs/index.html)
--   local hbDoc = require("hbDoc")

--[[/hbdoc
\class hbDoc
\brief The hbDoc table.
\details The hbDoc table contains functions for generating HTML documentation from C++ source code.
]]
local hbDoc = {}

--[[/hbdoc
\macro IS_WINDOWS
\brief True if running on Windows, false otherwise.
]]
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

-- Names that look like function calls/definitions but are control flow.
--[[/hbdoc
\macro NOT_FUNCTIONS
\brief A table of names that look like function calls/definitions but are control flow.
]]
local NOT_FUNCTIONS = {
    ["if"] = true, ["for"] = true, ["while"] = true, ["switch"] = true,
    ["catch"] = true, ["return"] = true, ["sizeof"] = true, ["else"] = true,
}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

--[[/hbdoc
\function trim
\brief Removes leading and trailing whitespace.
]]
local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

--[[/hbdoc
\function escapeHtml
\brief Escapes HTML-sensitive ampersand and angle-bracket characters.
]]
local function escapeHtml(s)
    return (tostring(s):gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

-- Replace text with spaces, keeping newlines, so string positions stay valid.
--[[/hbdoc
\function blankOut
\brief Replaces non-newline characters with spaces without changing string length.
]]
local function blankOut(text)
    return (text:gsub("[^\n]", " "))
end

-- Same length as the input, but comments are blanked so that braces, parens
-- and keywords inside them can't confuse structural matching.
--[[/hbdoc
\function maskComments
\brief Masks C and C++ comments while preserving source positions.
\details This keeps comment contents from interfering with structural scans.
String literals are not masked.
]]
local function maskComments(src)
    src = src:gsub("/%*.-%*/", blankOut)
    src = src:gsub("//[^\n]*", blankOut)
    return src
end

--[[/hbdoc
\function isDocLine
\brief Checks whether a source line begins with a triple-slash doc comment.
]]
local function isDocLine(line)
    return line:match("^%s*///") ~= nil
end

--[[/hbdoc
\function lineStartOf
\brief Finds the one-based start position of the line containing a position.
]]
local function lineStartOf(src, pos)
    while pos > 1 and src:sub(pos - 1, pos - 1) ~= "\n" do
        pos = pos - 1
    end
    return pos
end

-- Where does the contiguous block of /// lines directly above declPos start?
-- Blank lines between the docs and the declaration are tolerated.
--[[/hbdoc
\function docStartBefore
\brief Finds the documentation block immediately preceding a declaration.
\details Allows blank lines and ordinary line comments between the doc block
and declaration.
]]
local function docStartBefore(src, declPos)
    local start = lineStartOf(src, declPos)
    local pos = start
    local foundDoc = false
    while pos > 1 do
        local prevStart = lineStartOf(src, pos - 1)
        local line = src:sub(prevStart, pos - 2)
        if isDocLine(line) then
            start = prevStart
            foundDoc = true
        elseif line:match("^%s*//") or line:match("^%s*$") then
            if foundDoc then
                start = prevStart
            end
        else
            break
        end
        pos = prevStart
    end
    return foundDoc and start or lineStartOf(src, declPos)
end

-- Split "doc lines + declaration" into (docText, declarationText).
--[[/hbdoc
\function splitDocBlock
\brief Splits a snippet into leading triple-slash comments and declaration text.
]]
local function splitDocBlock(src)
    local pos = 1
    while pos <= #src do
        local lineEnd = src:find("\n", pos, true) or (#src + 1)
        local line = src:sub(pos, lineEnd - 1)
        if not (isDocLine(line) or line:match("^%s*$")) then
            break
        end
        pos = lineEnd + 1
    end
    return src:sub(1, pos - 1), src:sub(pos)
end

---------------------------------------------------------------------------
-- Comment parsing
---------------------------------------------------------------------------

-- Understands \brief, \details, \HTMLstart ... \HTMLend inside /// lines.
--[[/hbdoc
\function parseDocComments
\brief Parses triple-slash documentation into brief, details, and HTML fields.
\details Section content can span multiple lines. Text outside a recognized
section is ignored.
]]
local function parseDocComments(src)
    local docs, section, lines = {}, nil, {}

    local function flush()
        if section then
            docs[section] = trim(table.concat(lines, "\n"))
        end
        section, lines = nil, {}
    end

    for line in src:gmatch("[^\r\n]+") do
        local comment = line:match("^%s*///%s?(.*)$")
        if comment then
            local tag, rest = comment:match("^\\(%a+)%s*(.*)$")
            if tag == "brief" then
                docs.brief = trim(rest)
            elseif tag == "details" then
                flush()
                section, lines = "details", { rest }
            elseif tag == "HTMLstart" then
                flush()
                section, lines = "html", { rest }
            elseif tag == "HTMLend" then
                flush()
            elseif section then
                lines[#lines + 1] = comment
            end
        end
    end

    flush()
    return docs
end

--[[/hbdoc
\function parseTaggedDocBlock
\brief Parses a tagged Lua documentation block with the shared doc syntax.
]]
local function parseTaggedDocBlock(text)
    local docLines = {}
    for line in text:gmatch("[^\r\n]+") do
        local normalized = trim(line)
        if normalized ~= "" then
            docLines[#docLines + 1] = "/// " .. normalized
        end
    end
    return parseDocComments(table.concat(docLines, "\n"))
end

-- Collects "// <marker> brief" comments, each attached to the next
-- declaration line. A "/// \brief" in between overrides the short brief.
-- Used for "// PARAM" (inside a parameter list) and "// FIELD" (in a class).
--[[/hbdoc
\function collectAnnotated
\brief Collects marker comments and associates them with following declarations.
\details Returns entries containing declaration text and a brief description.
]]
local function collectAnnotated(text, marker, allowBriefOnly)
    local items, pending = {}, nil

    for line in text:gmatch("[^\r\n]+") do
        local brief = line:match("^%s*//%s*" .. marker .. "%s*(.-)%s*$")
        if brief then
            pending = { brief = brief }
        elseif allowBriefOnly and line:match("^%s*///%s*\\brief%s*") then
            local longBrief = line:match("^%s*///%s*\\brief%s*(.-)%s*$")
            pending = pending or {}
            pending.brief = longBrief
        elseif pending then
            local longBrief = line:match("^%s*///%s*\\brief%s*(.-)%s*$")
            if longBrief then
                pending.brief = longBrief
            elseif not (line:match("^%s*//") or line:match("^%s*$")) then
                -- Strip trailing comment and separator: "int a, // x" -> "int a"
                local decl = trim((line:gsub("%s*//.*$", "")))
                pending.decl = (decl:gsub("[,;]$", ""))
                items[#items + 1] = pending
                pending = nil
            end
        end
    end

    return items
end

---------------------------------------------------------------------------
-- Public parsing API
---------------------------------------------------------------------------

-- Parse one C++ function: its leading /// comments plus the definition.
-- (Classify() cuts these snippets out of a file for you.)
--[[/hbdoc
\function hbDoc.parseFunc
\brief Parses a documented C++ function snippet.
\details Returns the function name, its documentation, and annotated parameters.
]]
function hbDoc.parseFunc(funcSrc)
    local docText, decl = splitDocBlock(funcSrc)
    local docs = parseDocComments(docText)
    local func = {
        brief = docs.brief,
        details = docs.details,
        html = docs.html,
        params = {},
    }

    local masked = maskComments(decl)
    local name, openPos = masked:match("([%a_][%w_:~]*)%s*()%(")
    func.name = name
    if openPos then
        local _, closePos = masked:find("^%b()", openPos)
        if closePos then
            func.params = collectAnnotated(decl:sub(openPos + 1, closePos - 1), "PARAM")
        end
    end

    return func
end

--[[/hbdoc
\function collectDocumentedFields
\brief Collects triple-slash-documented fields from a struct body.
]]
local function collectDocumentedFields(text)
    local fields, pending = {}, nil
    for line in text:gmatch("[^\r\n]+") do
        local brief = line:match("^%s*///%s*\\brief%s*(.-)%s*$")
        if brief then
            pending = { brief = brief }
        elseif pending then
            if line:match("^%s*//") or line:match("^%s*$") then
                -- Skip comments and blank lines while looking for the declaration.
            else
                pending.decl = trim((line:gsub("%s*//.*$", "")):gsub("[,;]$", ""))
                fields[#fields + 1] = pending
                pending = nil
            end
        end
    end
    return fields
end

--[[/hbdoc
\function parseAggregate
\brief Parses a C++ class or struct snippet.
\details Parses the leading docs and documented fields; class fields can use
FIELD markers, while struct fields use their own brief comments.
]]
local function parseAggregate(typeSrc, typeName)
    local docText, decl = splitDocBlock(typeSrc)
    local docs = parseDocComments(docText)
    local aggregate = {
        brief = docs.brief,
        details = docs.details,
        html = docs.html,
        fields = {},
    }

    local masked = maskComments(decl)
    local name, bracePos = masked:match(typeName .. "%s+([%a_][%w_]*)[^;{]*()%{")
    aggregate.name = name
    if bracePos then
        local _, braceEnd = masked:find("^%b{}", bracePos)
        if braceEnd then
            local body = decl:sub(bracePos + 1, braceEnd - 1)
            aggregate.fields = typeName == "struct"
                and collectDocumentedFields(body)
                or collectAnnotated(body, "FIELD", true)
        end
    end

    return aggregate
end

-- Parse one C++ class or struct: its leading /// comments plus the full definition.
--[[/hbdoc
\function hbDoc.parseClass
\brief Parses one documented C++ class snippet.
]]
function hbDoc.parseClass(classSrc)
    return parseAggregate(classSrc, "class")
end

--[[/hbdoc
\function hbDoc.parseStruct
\brief Parses one documented C++ struct snippet.
]]
function hbDoc.parseStruct(structSrc)
    return parseAggregate(structSrc, "struct")
end

-- Merge a namespace's doc fields into a list, keeping the first value seen.
--[[/hbdoc
\function addNamespaceDoc
\brief Merges namespace documentation, retaining the first value for each field.
]]
local function addNamespaceDoc(list, doc)
    for _, existing in ipairs(list) do
        if existing.name == doc.name then
            existing.brief = existing.brief or doc.brief
            existing.details = existing.details or doc.details
            existing.html = existing.html or doc.html
            return
        end
    end
    list[#list + 1] = doc
end

-- Find every class, free function and documented namespace in a source string.
-- Classes and functions get a `namespace` field ("a::b") when declared inside one.
--[[/hbdoc
\function hbDoc.Classify
\brief Classifies C++ source into classes, structs, functions, macros, and namespaces.
\details Finds aggregate declarations, explicitly documented global macros and
variables, and free functions. Entities inside named namespaces retain their
qualified namespace.
]]
function hbDoc.Classify(fileSrc)
    local masked = maskComments(fileSrc)
    local classes, structs, funcs, macros, namespaces = {}, {}, {}, {}, {}

    -- Pass 0: namespace blocks, including nested ones and `namespace a::b {`.
    -- Anonymous namespaces add no name. Ranges come out in order of start.
    local nsRanges = {}
    local pos = 1
    while true do
        local s, e, localName = masked:find("%f[%w_]namespace%f[^%w_]%s*([%a_]?[%w_:]*)%s*%{", pos)
        if not s then break end
        local _, bodyEnd = masked:find("^%b{}", e)
        if not bodyEnd then break end
        nsRanges[#nsRanges + 1] = { start = s, bodyStart = e, bodyEnd = bodyEnd, name = localName }
        pos = e + 1 -- keep going inside, so nested namespaces are found too
    end

    local stack = {}
    for _, range in ipairs(nsRanges) do
        while #stack > 0 and stack[#stack].bodyEnd < range.bodyStart do
            stack[#stack] = nil
        end
        local parent = stack[#stack] and stack[#stack].full
        if range.name ~= "" then
            range.full = parent and (parent .. "::" .. range.name) or range.name
        else
            range.full = parent
        end
        stack[#stack + 1] = range

        if range.name ~= "" then
            local docStart = docStartBefore(fileSrc, range.start)
            local docs = parseDocComments(fileSrc:sub(docStart, lineStartOf(fileSrc, range.start) - 1))
            if docs.brief or docs.details or docs.html then
                addNamespaceDoc(namespaces, {
                    name = range.full, brief = docs.brief, details = docs.details, html = docs.html,
                })
            end
        end
    end

    -- Innermost named namespace containing a position (nil at global scope).
    local function namespaceAt(position)
        local inner
        for _, range in ipairs(nsRanges) do
            if position > range.bodyStart and position < range.bodyEnd then
                inner = range
            end
        end
        return inner and inner.full
    end

    -- Pass 1: classes and structs. Balanced-brace matching handles nested braces.
    local aggregateRanges = {}
    local function collectAggregates(typeName, destination, parse)
        local aggregatePos = 1
        while true do
            local s, e = masked:find("%f[%w_]" .. typeName .. "%s+[%a_][%w_]*[^;{]*%{", aggregatePos)
            if not s then break end
            local _, bodyEnd = masked:find("^%b{}", e)
            if not bodyEnd then break end

            local isEnum = masked:sub(math.max(1, s - 16), s - 1):match("enum%s*$")
            if isEnum then
                aggregatePos = bodyEnd + 1
            else
                local _, semi = masked:find("^%s*;", bodyEnd + 1)
                local stop = semi or bodyEnd
                local from = docStartBefore(fileSrc, s)
                local aggregate = parse(fileSrc:sub(from, stop))
                aggregate.namespace = namespaceAt(s)
                destination[#destination + 1] = aggregate
                aggregateRanges[#aggregateRanges + 1] = { s, stop }
                aggregatePos = stop + 1
            end
        end
    end
    collectAggregates("class", classes, hbDoc.parseClass)
    collectAggregates("struct", structs, hbDoc.parseStruct)
    table.sort(aggregateRanges, function(a, b) return a[1] < b[1] end)

    -- Pass 2: explicitly documented global variables and preprocessor macros.
    pos = 1
    while true do
        local markerStart, markerEnd, markedName = fileSrc:find("///%s*\\macro%s+([%a_][%w_]*)", pos)
        if not markerStart then break end

        local lineEnd = fileSrc:find("\n", markerEnd + 1, true) or (#fileSrc + 1)
        local declPos = lineEnd + 1
        while declPos <= #fileSrc do
            local nextEnd = fileSrc:find("\n", declPos, true) or (#fileSrc + 1)
            local line = fileSrc:sub(declPos, nextEnd - 1)
            if line:match("^%s*$") or line:match("^%s*//") then
                declPos = nextEnd + 1
            else
                break
            end
        end

        local inAggregate = false
        for _, range in ipairs(aggregateRanges) do
            if markerStart >= range[1] and markerStart <= range[2] then
                inAggregate = true
                break
            end
        end
        if not inAggregate and declPos <= #fileSrc then
            local declEnd
            local declarationLineEnd = fileSrc:find("\n", declPos, true) or (#fileSrc + 1)
            local declarationLine = fileSrc:sub(declPos, declarationLineEnd - 1)
            if declarationLine:match("^%s*#%s*define%f[%W]") then
                declEnd = declarationLineEnd - 1
            else
                declEnd = masked:find(";", declPos, true) or (declarationLineEnd - 1)
            end

            local docStart = docStartBefore(fileSrc, markerStart)
            local docs = parseDocComments(fileSrc:sub(docStart, declPos - 1))
            macros[#macros + 1] = {
                name = markedName,
                decl = trim(fileSrc:sub(declPos, declEnd)),
                brief = docs.brief,
                details = docs.details,
                html = docs.html,
                namespace = namespaceAt(markerStart),
            }
        end
        pos = markerEnd + 1
    end

    -- Pass 3: free functions. Class bodies are blanked first so methods
    -- aren't reported as free functions.
    local pieces, last = {}, 1
    for _, range in ipairs(aggregateRanges) do
        pieces[#pieces + 1] = masked:sub(last, range[1] - 1)
        pieces[#pieces + 1] = blankOut(masked:sub(range[1], range[2]))
        last = range[2] + 1
    end
    pieces[#pieces + 1] = masked:sub(last)
    local outside = table.concat(pieces)

    pos = 1
    while true do
        local s, e, name = outside:find("([%a_][%w_:~]*)%s*%b()", pos)
        if not s then break end

        local _, bodyEnd = outside:find("^[%s%w_]*%b{}", e + 1) -- allows const/noexcept/override
        if bodyEnd and not NOT_FUNCTIONS[name] then
            local from = docStartBefore(fileSrc, s)
            local func = hbDoc.parseFunc(fileSrc:sub(from, bodyEnd))
            func.namespace = namespaceAt(s)
            funcs[#funcs + 1] = func
            pos = bodyEnd + 1
        else
            pos = e + 1
        end
    end

    return { classes = classes, structs = structs, funcs = funcs, macros = macros, namespaces = namespaces }
end

--[[/hbdoc
\function hbDoc.ClassifyLua
\brief Classifies Lua source using hbDoc-tagged comment blocks.
\details Recognizes documented classes, functions, and macros, returning the
same general result shape as the C++ classifier.
]]
function hbDoc.ClassifyLua(fileSrc)
    local classes, funcs, macros = {}, {}, {}
    local marker = "--[[/hbdoc"
    local pos = 1

    while true do
        local blockStart = fileSrc:find(marker, pos, true)
        while blockStart do
            local lineStart = lineStartOf(fileSrc, blockStart)
            local lineEnd = fileSrc:find("\n", blockStart + #marker, true) or (#fileSrc + 1)
            local beforeMarker = fileSrc:sub(lineStart, blockStart - 1)
            local afterMarker = fileSrc:sub(blockStart + #marker, lineEnd - 1)
            if beforeMarker:match("^%s*$") and afterMarker:match("^%s*$") then
                break
            end
            pos = blockStart + #marker
            blockStart = fileSrc:find(marker, pos, true)
        end
        if not blockStart then break end
        local contentStart = blockStart + #marker
        local blockEnd = fileSrc:find("]]", contentStart, true)
        if not blockEnd then
            error("Unterminated hbDoc comment block in Lua source", 0)
        end

        local content = fileSrc:sub(contentStart, blockEnd - 1)
        local docs = parseTaggedDocBlock(content)
        local kind, name
        for line in content:gmatch("[^\r\n]+") do
            kind, name = trim(line):match("^\\(%a+)%s+([%w_%.:]+)")
            if kind == "class" or kind == "function" or kind == "macro" then
                break
            end
            kind, name = nil, nil
        end

        if kind then
            local declPos = blockEnd + 2
            while declPos <= #fileSrc do
                local lineEnd = fileSrc:find("\n", declPos, true) or (#fileSrc + 1)
                local line = fileSrc:sub(declPos, lineEnd - 1)
                if line:match("^%s*$") or line:match("^%s*%-%-") then
                    declPos = lineEnd + 1
                else
                    break
                end
            end

            local lineEnd = fileSrc:find("\n", declPos, true) or (#fileSrc + 1)
            local declaration = trim(fileSrc:sub(declPos, lineEnd - 1))
            local entry = {
                name = name,
                decl = declaration,
                brief = docs.brief,
                details = docs.details,
                html = docs.html,
            }

            if kind == "class" then
                entry.fields = {}
                classes[#classes + 1] = entry
            elseif kind == "macro" then
                macros[#macros + 1] = entry
            else
                entry.params = {}
                local params = fileSrc:sub(declPos):match("function%s+[%w_%.:]+%s*(%b())")
                if params then
                    for param in params:sub(2, -2):gmatch("[^,]+") do
                        local paramName = trim(param)
                        if paramName ~= "" then
                            entry.params[#entry.params + 1] = { decl = paramName }
                        end
                    end
                end
                funcs[#funcs + 1] = entry
            end
        end

        pos = blockEnd + 2
    end

    return { classes = classes, structs = {}, funcs = funcs, macros = macros, namespaces = {} }
end

---------------------------------------------------------------------------
-- HTML output
---------------------------------------------------------------------------

local INDEX_LINK = '<a href="index.html">&larr; Back to index</a>'

--[[/hbdoc
\function anchorId
\brief Converts a name to a safe HTML anchor identifier.
]]
local function anchorId(name)
    return (tostring(name or "unnamed"):gsub("[^%w_]", "_"))
end

-- "a::b::Foo" -> "a.b.Foo"; anything else unusual in a file name becomes "_".
--[[/hbdoc
\function fileBase
\brief Converts a qualified name into a safe output-file stem.
]]
local function fileBase(name)
    return (tostring(name or "unnamed"):gsub("::", "."):gsub("[^%w_%.]", "_"))
end

--[[/hbdoc
\function qualifiedName
\brief Returns an entry's fully qualified name when it has a namespace.
]]
local function qualifiedName(entry)
    local name = entry.name or "(unnamed)"
    if entry.namespace then
        return entry.namespace .. "::" .. name
    end
    return name
end

--[[/hbdoc
\function shortName
\brief Returns the final component of a qualified name.
]]
local function shortName(qualified)
    return qualified:match("([^:]+)$") or qualified
end

--[[/hbdoc
\function renderHead
\brief Renders an entry heading, brief, details, and optional HTML.
]]
local function renderHead(out, title, entry, id, preface)
    out[#out + 1] = "<h1" .. (id and (' id="' .. id .. '"') or "") .. ">" .. escapeHtml(title) .. "</h1>"
    if preface then
        out[#out + 1] = preface
    end
    if entry.brief then
        out[#out + 1] = '<p class="brief"><strong>Brief:</strong> ' .. escapeHtml(entry.brief) .. "</p>"
    end
    if entry.details then
        out[#out + 1] = '<p class="details"><strong>Details:</strong> ' .. escapeHtml(entry.details) .. "</p>"
    end
    if entry.html then
        out[#out + 1] = entry.html -- raw on purpose: this is what \HTMLstart is for
    end
end

--[[/hbdoc
\function renderEntry
\brief Renders a documented entry and its list of members or parameters.
]]
local function renderEntry(out, title, entry, itemsTitle, items, id, preface)
    renderHead(out, title, entry, id, preface)
    out[#out + 1] = "<h2>" .. itemsTitle .. '</h2><ul class="' .. itemsTitle:lower() .. '">'
    for _, item in ipairs(items) do
        out[#out + 1] = "<li><strong>" .. escapeHtml(item.decl or "?") .. "</strong>: "
            .. escapeHtml(item.brief or "") .. "</li>"
    end
    out[#out + 1] = "</ul>"
end

--[[/hbdoc
\macro DEFAULT_STYLESHEET
\brief The default stylesheet copied into each documentation output folder.
]]
local DEFAULT_STYLESHEET = "hbdoc.css"
-- We want images to fit, and for the text to look kind of nice.
--[[/hbdoc
\macro DEFAULT_STYLESHEET_CONTENT
\brief Default CSS for readable pages and size-constrained images.
]]
local DEFAULT_STYLESHEET_CONTENT = [[
img {
    max-width: 100%;
    max-height: 32rem;
    width: auto;
    height: auto;
    object-fit: contain;
}

html {
    font-family: Arial, sans-serif;
}
]]

-- Everything on one page.
--[[/hbdoc
\function hbDoc.GenerateHTMLDocs
\brief Renders parsed entities as a single HTML document.
]]
function hbDoc.GenerateHTMLDocs(codebaseParsed)
    local out = { "<html><body>" }
    for _, class in ipairs(codebaseParsed.classes) do
        renderEntry(out, qualifiedName(class), class, "Members", class.fields)
    end
    for _, struct in ipairs(codebaseParsed.structs or {}) do
        renderEntry(out, qualifiedName(struct), struct, "Fields", struct.fields)
    end
    for _, func in ipairs(codebaseParsed.funcs) do
        renderEntry(out, qualifiedName(func), func, "Parameters", func.params)
    end
    for _, macro in ipairs(codebaseParsed.macros or {}) do
        renderHead(out, macro.name, macro)
        out[#out + 1] = "<pre><code>" .. escapeHtml(macro.decl or "") .. "</code></pre>"
    end
    out[#out + 1] = "</body></html>"
    return table.concat(out)
end

--[[/hbdoc
\function wrapPage
\brief Wraps a content fragment in a complete HTML page.
]]
local function wrapPage(title, body, nav, stylesheet)
    return table.concat({
        '<!DOCTYPE html><html><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>", escapeHtml(title), "</title>",
        '<link rel="stylesheet" href="' .. DEFAULT_STYLESHEET .. '">',
        stylesheet and ('<link rel="stylesheet" href="' .. escapeHtml(stylesheet) .. '">') or "",
        "</head><body>",
        nav and ("<nav>" .. nav .. "</nav>") or "",
        "<main>", body, "</main></body></html>",
    })
end

--[[/hbdoc
\function briefSuffix
\brief Renders an entry's brief as a short HTML suffix.
]]
local function briefSuffix(entry)
    return entry.brief and (" &mdash; " .. escapeHtml(entry.brief)) or ""
end

--[[/hbdoc
\function linkItem
\brief Renders a linked list item with the entry's brief, if available.
]]
local function linkItem(href, text, entry)
    return '<li><a href="' .. href .. '">' .. escapeHtml(text) .. "</a>" .. briefSuffix(entry) .. "</li>"
end

-- Multi-page output. Returns { ["index.html"] = html, ... }
--   index.html               hub: namespace tree, plus global classes, structs and functions
--   namespace.<a.b>.html     one page per namespace (docs, child namespaces, classes, structs, functions)
--   <a.b.Class>.html         one page per class
--   functions.html           every free function (only if there are any)
-- opts.stylesheet: href of a stylesheet to link from every page.
--[[/hbdoc
\function hbDoc.GenerateSite
\brief Renders parsed entities as a multi-page HTML site.
\details Returns a map from output file names to HTML content, including an
index and detail pages for documented classes, structs, functions, and macros.
]]
function hbDoc.GenerateSite(codebaseParsed, opts)
    opts = opts or {}
    local files = {}
    local usedNames = { ["index.html"] = true, ["functions.html"] = true, ["macros.html"] = true }

    --[[/hbdoc
    \function uniqueFileName
    \brief Allocates a unique HTML output filename.
    ]]
    local function uniqueFileName(base)
        local file, n = base .. ".html", 1
        while usedNames[file:lower()] do
            n = n + 1
            file = base .. "_" .. n .. ".html"
        end
        usedNames[file:lower()] = true
        return file
    end

    -- Namespace tree. Parents are created implicitly: "a::b" implies "a".
    local namespaces, rootNamespaces = {}, {}
    --[[/hbdoc
    \function ensureNamespace
    \brief Retrieves or creates a namespace node and its parent chain.
    ]]
    local function ensureNamespace(name)
        local ns = namespaces[name]
        if ns then return ns end
        ns = { name = name, classes = {}, structs = {}, funcs = {}, macros = {}, children = {} }
        namespaces[name] = ns
        local parentName = name:match("^(.*)::[^:]+$")
        if parentName then
            local parent = ensureNamespace(parentName)
            parent.children[#parent.children + 1] = ns
            ns.parent = parent
        else
            rootNamespaces[#rootNamespaces + 1] = ns
        end
        return ns
    end

    for _, doc in ipairs(codebaseParsed.namespaces or {}) do
        local ns = ensureNamespace(doc.name)
        ns.brief, ns.details, ns.html = doc.brief, doc.details, doc.html
    end

    local rootClasses, rootStructs, rootFuncs, rootMacros = {}, {}, {}, {}
    for _, class in ipairs(codebaseParsed.classes) do
        local list = class.namespace and ensureNamespace(class.namespace).classes or rootClasses
        list[#list + 1] = class
    end
    for _, struct in ipairs(codebaseParsed.structs or {}) do
        local list = struct.namespace and ensureNamespace(struct.namespace).structs or rootStructs
        list[#list + 1] = struct
    end
    for _, func in ipairs(codebaseParsed.funcs) do
        local list = func.namespace and ensureNamespace(func.namespace).funcs or rootFuncs
        list[#list + 1] = func
    end
    for _, macro in ipairs(codebaseParsed.macros or {}) do
        local list = macro.namespace and ensureNamespace(macro.namespace).macros or rootMacros
        list[#list + 1] = macro
    end

    --[[/hbdoc
    \function byName
    \brief Sorts namespace entries by name.
    ]]
    local function byName(a, b) return a.name < b.name end
    table.sort(rootNamespaces, byName)
    local namespaceList = {}
    for _, ns in pairs(namespaces) do
        table.sort(ns.children, byName)
        namespaceList[#namespaceList + 1] = ns
    end
    table.sort(namespaceList, byName)

    -- Names for everything that gets a page or an anchor.
    local namespaceFile, classFile, structFile, funcId, macroId = {}, {}, {}, {}, {}
    for _, ns in ipairs(namespaceList) do
        namespaceFile[ns] = uniqueFileName("namespace." .. fileBase(ns.name))
    end
    for _, class in ipairs(codebaseParsed.classes) do
        classFile[class] = uniqueFileName(fileBase(qualifiedName(class)))
    end
    for _, struct in ipairs(codebaseParsed.structs or {}) do
        structFile[struct] = uniqueFileName(fileBase(qualifiedName(struct)))
    end
    local idCounts = {}
    for _, func in ipairs(codebaseParsed.funcs) do
        local base = anchorId(qualifiedName(func))
        idCounts[base] = (idCounts[base] or 0) + 1 -- overloads get _2, _3, ...
        funcId[func] = idCounts[base] == 1 and base or (base .. "_" .. idCounts[base])
    end
    local macroIdCounts = {}
    for _, macro in ipairs(codebaseParsed.macros or {}) do
        local base = anchorId(qualifiedName(macro))
        macroIdCounts[base] = (macroIdCounts[base] or 0) + 1
        macroId[macro] = macroIdCounts[base] == 1 and base or (base .. "_" .. macroIdCounts[base])
    end

    --[[/hbdoc
    \function namespaceLine
    \brief Renders a link to a namespace's detail page.
    ]]
    local function namespaceLine(ns)
        return '<p class="namespace">Namespace: <a href="' .. namespaceFile[ns] .. '">'
            .. escapeHtml(ns.name) .. "</a></p>"
    end

    --[[/hbdoc
    \function namespaceTree
    \brief Renders a namespace list, optionally including descendants.
    ]]
    local function namespaceTree(out, list, recursive)
        out[#out + 1] = '<ul class="namespaces">'
        for _, ns in ipairs(list) do
            out[#out + 1] = '<li><a href="' .. namespaceFile[ns] .. '">' .. escapeHtml(shortName(ns.name))
                .. "</a>" .. briefSuffix(ns)
            if recursive and #ns.children > 0 then
                namespaceTree(out, ns.children, true)
            end
            out[#out + 1] = "</li>"
        end
        out[#out + 1] = "</ul>"
    end

    --[[/hbdoc
    \function classList
    \brief Renders links to a list of classes.
    ]]
    local function classList(out, classes)
        if #classes == 0 then return end
        out[#out + 1] = '<h2>Classes</h2><ul class="classes">'
        for _, class in ipairs(classes) do
            out[#out + 1] = linkItem(classFile[class], class.name or "(unnamed)", class)
        end
        out[#out + 1] = "</ul>"
    end

    --[[/hbdoc
    \function structList
    \brief Renders links to a list of structs.
    ]]
    local function structList(out, structs)
        if #structs == 0 then return end
        out[#out + 1] = '<h2>Structs</h2><ul class="structs">'
        for _, struct in ipairs(structs) do
            out[#out + 1] = linkItem(structFile[struct], struct.name or "(unnamed)", struct)
        end
        out[#out + 1] = "</ul>"
    end

    --[[/hbdoc
    \function functionList
    \brief Renders links to a list of functions.
    ]]
    local function functionList(out, funcs)
        if #funcs == 0 then return end
        out[#out + 1] = '<h2>Functions</h2><ul class="functions">'
        for _, func in ipairs(funcs) do
            out[#out + 1] = linkItem("functions.html#" .. funcId[func], func.name or "(unnamed)", func)
        end
        out[#out + 1] = "</ul>"
    end

    --[[/hbdoc
    \function macroList
    \brief Renders links to a list of macros.
    ]]
    local function macroList(out, macros)
        if #macros == 0 then return end
        out[#out + 1] = '<h2>Macros</h2><ul class="macros">'
        for _, macro in ipairs(macros) do
            out[#out + 1] = linkItem("macros.html#" .. macroId[macro], macro.name or "(unnamed)", macro)
        end
        out[#out + 1] = "</ul>"
    end

    -- Class pages
    for _, class in ipairs(codebaseParsed.classes) do
        local body = {}
        local preface = class.namespace and namespaceLine(namespaces[class.namespace]) or nil
        renderEntry(body, qualifiedName(class), class, "Members", class.fields, nil, preface)
        files[classFile[class]] = wrapPage(qualifiedName(class), table.concat(body), INDEX_LINK, opts.stylesheet)
    end

    -- Struct pages
    for _, struct in ipairs(codebaseParsed.structs or {}) do
        local body = {}
        local preface = struct.namespace and namespaceLine(namespaces[struct.namespace]) or nil
        renderEntry(body, qualifiedName(struct), struct, "Fields", struct.fields, nil, preface)
        files[structFile[struct]] = wrapPage(qualifiedName(struct), table.concat(body), INDEX_LINK, opts.stylesheet)
    end

    -- Namespace pages
    for _, ns in ipairs(namespaceList) do
        local body = {}
        renderHead(body, "namespace " .. ns.name, ns, nil, ns.parent and namespaceLine(ns.parent) or nil)
        if #ns.children > 0 then
            body[#body + 1] = "<h2>Namespaces</h2>"
            namespaceTree(body, ns.children, false)
        end
        classList(body, ns.classes)
        structList(body, ns.structs)
        functionList(body, ns.funcs)
        macroList(body, ns.macros)
        files[namespaceFile[ns]] = wrapPage("namespace " .. ns.name, table.concat(body), INDEX_LINK, opts.stylesheet)
    end

    if #(codebaseParsed.macros or {}) > 0 then
        local body = {}
        for _, macro in ipairs(codebaseParsed.macros) do
            body[#body + 1] = '<section class="macro" id="' .. macroId[macro] .. '">'
            renderHead(body, qualifiedName(macro), macro)
            body[#body + 1] = "<pre><code>" .. escapeHtml(macro.decl or "") .. "</code></pre>"
            body[#body + 1] = "</section>"
        end
        files["macros.html"] = wrapPage("Macros", table.concat(body), INDEX_LINK, opts.stylesheet)
    end

    -- All functions on one page
    if #codebaseParsed.funcs > 0 then
        local body = {}
        for _, func in ipairs(codebaseParsed.funcs) do
            renderEntry(body, qualifiedName(func), func, "Parameters", func.params, funcId[func])
        end
        files["functions.html"] = wrapPage("Functions", table.concat(body), INDEX_LINK, opts.stylesheet)
    end

    -- Hub
    local index = { "<h1>Documentation</h1>" }
    if #rootNamespaces > 0 then
        index[#index + 1] = "<h2>Namespaces</h2>"
        namespaceTree(index, rootNamespaces, true)
    end
    classList(index, rootClasses)
    structList(index, rootStructs)
    functionList(index, rootFuncs)
    macroList(index, rootMacros)
    if #codebaseParsed.funcs > 0 then
        index[#index + 1] = '<p class="all-functions"><a href="functions.html">All functions</a></p>'
    end
    if #(codebaseParsed.macros or {}) > 0 then
        index[#index + 1] = '<p class="all-macros"><a href="macros.html">All macros</a></p>'
    end
    files["index.html"] = wrapPage("Documentation", table.concat(index), nil, opts.stylesheet)

    return files
end

---------------------------------------------------------------------------
-- Files and shell helpers
---------------------------------------------------------------------------

--[[/hbdoc
\function readFile
\brief Reads and returns the complete contents of a file.
]]
local function readFile(path, mode)
    local f = assert(io.open(path, mode or "r"))
    local text = f:read("*a")
    f:close()
    return text
end

--[[/hbdoc
\function writeFile
\brief Writes text to a file, asserting if it cannot be opened.
]]
local function writeFile(path, text, mode)
    local f = assert(io.open(path, mode or "w"))
    f:write(text)
    f:close()
end

-- Forward slashes only, no leading "./".
--[[/hbdoc
\function normalizePath
\brief Normalizes separators to forward slashes and removes a leading dot slash.
]]
local function normalizePath(p)
    local out = p:gsub("\\", "/"):gsub("^%./", "")
    return out
end

--[[/hbdoc
\function shellLines
\brief Runs a shell command and returns its non-empty output lines.
]]
local function shellLines(cmd)
    local pipe = assert(io.popen(cmd), "Unable to run: " .. cmd)
    local lines = {}
    for line in pipe:lines() do
        local clean = line:gsub("\r$", "")
        if clean ~= "" then
            lines[#lines + 1] = clean
        end
    end
    pipe:close()
    return lines
end

--[[/hbdoc
\function currentDir
\brief Returns the current working directory with normalized separators.
]]
local function currentDir()
    return normalizePath(shellLines(IS_WINDOWS and "cd" or "pwd")[1] or "")
end

-- Every file under `base` (or `base` itself if it is a file), as paths
-- relative to the working directory.
--[[/hbdoc
\function listTree
\brief Lists files under a path, excluding files inside Git metadata folders.
]]
local function listTree(base)
    local results = {}
    local function add(path)
        if not (path:match("^%.git/") or path:find("/%.git/")) then
            results[#results + 1] = path
        end
    end

    if IS_WINDOWS then
        local cwd = currentDir():lower()
        local winBase = base:gsub("/", "\\")
        for _, line in ipairs(shellLines(('dir /b /s /a-d "%s" 2>nul'):format(winBase))) do
            local path = normalizePath(line)
            if path:lower():sub(1, #cwd + 1) == cwd .. "/" then
                path = path:sub(#cwd + 2)
            end
            add(path)
        end
    else
        for _, line in ipairs(shellLines(('find "%s" -type f 2>/dev/null'):format(base))) do
            add(normalizePath(line))
        end
    end
    return results
end

--[[/hbdoc
\function listFiles
\brief Lists files beneath a directory that end with a specified extension.
]]
local function listFiles(dir, ext)
    local files = {}
    for _, path in ipairs(listTree(dir)) do
        if path:lower():sub(-#ext) == ext then
            files[#files + 1] = path
        end
    end
    table.sort(files)
    return files
end

--[[/hbdoc
\function ensureDir
\brief Creates an output directory and reports failure.
]]
local function ensureDir(dir)
    local cmd
    if IS_WINDOWS then
        local winDir = dir:gsub("/", "\\")
        cmd = ('if not exist "%s" mkdir "%s"'):format(winDir, winDir)
    else
        cmd = ('mkdir -p "%s"'):format(dir)
    end
    local ok = os.execute(cmd)
    assert(ok == true or ok == 0, "Unable to create " .. dir)
end

--[[/hbdoc
\function baseName
\brief Returns the final path component.
]]
local function baseName(path)
    return normalizePath(path):match("([^/]+)$") or path
end

--[[/hbdoc
\macro IMAGE_EXTENSIONS
\brief Image formats copied or converted by the build.
]]
local IMAGE_EXTENSIONS = {
    bmp = true, gif = true, jpeg = true, jpg = true, png = true,
    tif = true, tiff = true, webp = true,
}

local cachedImageMagick

--[[/hbdoc
\function findImageMagick
\brief Locates ImageMagick using configuration, PATH, or standard Windows installs.
]]
local function findImageMagick()
    if cachedImageMagick then
        return cachedImageMagick
    end

    local candidates = {}
    local configured = os.getenv("HB_DOC_MAGICK")
    if configured then
        candidates[#candidates + 1] = configured
    end
    for _, candidate in ipairs(shellLines(IS_WINDOWS and "where magick.exe 2>nul" or "command -v magick 2>/dev/null")) do
        candidates[#candidates + 1] = candidate
    end
    if IS_WINDOWS then
        for _, envName in ipairs({ "ProgramW6432", "ProgramFiles" }) do
            local programFiles = os.getenv(envName)
            if programFiles then
                for _, directory in ipairs(shellLines(('dir /b /ad "%s\\ImageMagick*" 2>nul'):format(programFiles))) do
                    candidates[#candidates + 1] = programFiles .. "\\" .. directory .. "\\magick.exe"
                end
            end
        end
    end

    for _, candidate in ipairs(candidates) do
        local executable = io.open(candidate, "rb")
        if executable then
            executable:close()
            cachedImageMagick = candidate
            return candidate
        end
    end

    error("ImageMagick was not found. Install it and add magick to PATH, or set HB_DOC_MAGICK to magick.exe.", 0)
end

--[[/hbdoc
\function shellQuote
\brief Quotes a value for passing as one shell argument on the current platform.
]]
local function shellQuote(value)
    if IS_WINDOWS then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

--[[/hbdoc
\function convertImage
\brief Converts one image to the requested PNG output path using ImageMagick.
]]
local function convertImage(inputPath, outputPath)
    local executable = findImageMagick()
    local command = table.concat({
        shellQuote(executable),
        shellQuote(inputPath),
        shellQuote(outputPath),
    }, " ")
    if IS_WINDOWS then
        command = 'cmd /S /C "' .. command .. '"'
    end
    local ok, reason, code = os.execute(command)
    assert(ok == true or ok == 0,
        ("ImageMagick failed to convert %s (%s: %s)"):format(inputPath, tostring(reason), tostring(code)))
    local output = io.open(outputPath, "rb")
    assert(output, "ImageMagick did not create " .. outputPath)
    output:close()
end

--[[/hbdoc
\function convertAndCopyImages
\brief Copies PNG files and converts supported image files into an output folder.
]]
local function convertAndCopyImages(inputDir, outputDir)
    local count = 0
    for _, inputPath in ipairs(listTree(inputDir)) do
        local extension = inputPath:match("%.([%w_]+)$")
        if extension and IMAGE_EXTENSIONS[extension:lower()] then
            local outputName = baseName(inputPath):gsub("%.[%w_]+$", ".png")
            local outputPath = outputDir .. "/" .. outputName
            if extension:lower() == "png" then
                writeFile(outputPath, readFile(inputPath, "rb"), "wb")
            else
                convertImage(inputPath, outputPath)
            end
            count = count + 1
        end
    end
    return count
end

---------------------------------------------------------------------------
-- Include files (gitignore-style, but listing what to document)
--
--   # comment
--   src/**/*.cpp        glob; * and ? stay inside one path segment, ** spans folders
--   include/            a trailing / (or naming a folder) means everything inside
--   *.h                 no slash: matches in any folder
--   /main.cpp           leading slash: anchored (same as main.cpp at the root)
--   !src/legacy/        exclude. Rules apply in order; the last match wins.
--
-- Paths are relative to the working directory. Only C/C++ source and header
-- files are picked up.
---------------------------------------------------------------------------

--[[/hbdoc
\macro SOURCE_EXTENSIONS
\brief Source file extensions accepted by include rules.
]]
local SOURCE_EXTENSIONS = {
    c = true, cc = true, cpp = true, cxx = true, inl = true, ipp = true,
    h = true, hh = true, hpp = true, hxx = true, lua = true,
}


--[[/hbdoc
\function isSourceFile
\brief Checks whether a path has a supported source-code extension.
]]
local function isSourceFile(path)
    local ext = path:match("%.([%w_]+)$")
    return ext ~= nil and SOURCE_EXTENSIONS[ext:lower()] == true
end

--[[/hbdoc
\function splitPath
\brief Splits a normalized path into its path segments.
]]
local function splitPath(path)
    local segments = {}
    for seg in path:gmatch("[^/]+") do
        segments[#segments + 1] = seg
    end
    return segments
end

--[[/hbdoc
\function compileGlob
\brief Compiles a path glob into matchable path-segment patterns.
]]
local function compileGlob(pattern)
    local segs = {}
    for _, seg in ipairs(splitPath(pattern)) do
        if seg == "**" then
            segs[#segs + 1] = { any = true }
        else
            local lua = seg:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", "[^/]*"):gsub("%?", "[^/]")
            segs[#segs + 1] = { lua = "^" .. lua .. "$" }
        end
    end
    return segs
end

--[[/hbdoc
\function globMatches
\brief Checks whether compiled glob segments match path segments.
]]
local function globMatches(segs, pathSegs)
    local function walk(i, j)
        if i > #segs then
            return j > #pathSegs
        end
        if segs[i].any then
            for k = j, #pathSegs + 1 do
                if walk(i + 1, k) then return true end
            end
            return false
        end
        if j > #pathSegs then
            return false
        end
        local name = pathSegs[j]
        if IS_WINDOWS then name = name:lower() end
        return name:match(segs[i].lua) ~= nil and walk(i + 1, j + 1)
    end
    return walk(1, 1)
end

--[[/hbdoc
\function parseIncludeRule
\brief Parses one inclusion or exclusion glob rule.
\details A leading exclamation mark excludes matching paths; a trailing slash
includes a folder and its descendants.
]]
local function parseIncludeRule(line)
    local negated = false
    local pattern = line
    if pattern:sub(1, 1) == "!" then
        negated, pattern = true, pattern:sub(2)
    end
    pattern = normalizePath(trim(pattern))
    if pattern == "" then return nil end
    if IS_WINDOWS then pattern = pattern:lower() end

    if pattern:sub(-1) == "/" then pattern = pattern .. "**" end
    if not pattern:find("/", 1, true) then pattern = "**/" .. pattern end
    pattern = pattern:gsub("^/", "")

    -- Where to start listing: the literal folders before the first wildcard.
    local base = {}
    for _, seg in ipairs(splitPath(pattern)) do
        if seg:find("[%*%?]") then break end
        base[#base + 1] = seg
    end

    -- A rule also matches everything inside a folder it names.
    local exact = compileGlob(pattern)
    local inside = compileGlob(pattern .. "/**")

    return {
        negated = negated,
        base = #base > 0 and table.concat(base, "/") or ".",
        matches = function(pathSegs)
            return globMatches(exact, pathSegs) or globMatches(inside, pathSegs)
        end,
    }
end

-- Read an include file and return the matching source files (sorted).
--[[/hbdoc
\function hbDoc.resolveIncludeFile
\brief Resolves an include-rules file to a sorted list of source paths.
]]
function hbDoc.resolveIncludeFile(includePath)
    local rules = {}
    for line in readFile(includePath):gmatch("[^\r\n]+") do
        local text = trim(line)
        if text ~= "" and text:sub(1, 1) ~= "#" then
            rules[#rules + 1] = parseIncludeRule(text)
        end
    end

    local seen, candidates, bases = {}, {}, {}
    for _, rule in ipairs(rules) do
        if not rule.negated and not bases[rule.base] then
            bases[rule.base] = true
            for _, path in ipairs(listTree(rule.base)) do
                if not seen[path] then
                    seen[path] = true
                    candidates[#candidates + 1] = path
                end
            end
        end
    end
    table.sort(candidates)

    local files = {}
    for _, path in ipairs(candidates) do
        if isSourceFile(path) then
            local pathSegs = splitPath(IS_WINDOWS and path:lower() or path)
            local included = false
            for _, rule in ipairs(rules) do
                if rule.matches(pathSegs) then
                    included = not rule.negated
                end
            end
            if included then
                files[#files + 1] = path
            end
        end
    end
    return files
end

---------------------------------------------------------------------------
-- Build + command line
---------------------------------------------------------------------------

-- opts.files      list of source file paths (required)
-- opts.outDir     output folder (default "docs")
-- opts.sharedCss  path of a stylesheet to copy into outDir and link from every page
-- opts.imageDir   optional directory containing images to copy/convert to PNG
--[[/hbdoc
\function hbDoc.build
\brief Classifies source files and writes the generated documentation site.
\details Supports Lua and C/C++ sources, an optional stylesheet, and optional
image copying or conversion.
]]
function hbDoc.build(opts)
    assert(opts.files and #opts.files > 0, "No source files to document")
    local outDir = opts.outDir or "docs"

    local all = { classes = {}, structs = {}, funcs = {}, macros = {}, namespaces = {} }
    for _, path in ipairs(opts.files) do
        local extension = path:match("%.([%w_]+)$")
        local parsed = extension and extension:lower() == "lua"
            and hbDoc.ClassifyLua(readFile(path))
            or hbDoc.Classify(readFile(path))
        table.move(parsed.classes, 1, #parsed.classes, #all.classes + 1, all.classes)
        table.move(parsed.structs, 1, #parsed.structs, #all.structs + 1, all.structs)
        table.move(parsed.funcs, 1, #parsed.funcs, #all.funcs + 1, all.funcs)
        table.move(parsed.macros, 1, #parsed.macros, #all.macros + 1, all.macros)
        for _, doc in ipairs(parsed.namespaces) do
            addNamespaceDoc(all.namespaces, doc)
        end
    end

    ensureDir(outDir)
    writeFile(outDir .. "/" .. DEFAULT_STYLESHEET, DEFAULT_STYLESHEET_CONTENT)
    if opts.imageDir then
        convertAndCopyImages(opts.imageDir, outDir)
    end

    local stylesheet
    if opts.sharedCss then
        stylesheet = baseName(opts.sharedCss)
        writeFile(outDir .. "/" .. stylesheet, readFile(opts.sharedCss, "rb"), "wb")
    end

    for name, html in pairs(hbDoc.GenerateSite(all, { stylesheet = stylesheet })) do
        writeFile(outDir .. "/" .. name, html)
    end

    return all
end

--[[/hbdoc
\macro USAGE
\brief Command-line usage and option reference.
]]
local USAGE = [[
Usage: lua hbDoc.lua --include=FILE [--sharedcss=FILE] [--images=DIR] [--out=DIR]
       lua hbDoc.lua --test [--sharedcss=FILE] [--images=DIR] [--out=DIR]
       lua hbDoc.lua --self [--out=DIR]

  --include=FILE    gitignore-style list of C/C++ or Lua source files to document
  --sharedcss=FILE  stylesheet copied into the output folder and linked from every page
  --images=DIR      image folder; images are copied or converted to PNG
  --out=DIR         output folder (default: docs)
  --test            document test/src/*.cpp into test/docs
  --self            document hbDoc/hbDoc.lua into hbDoc/docs
]]

--[[/hbdoc
\function parseArgs
\brief Parses command-line options into a lowercase-keyed table.
\details Supports both `--key=value` and `--key value` forms.
]]
local function parseArgs(argv)
    local args, i = {}, 1
    while i <= #argv do
        local raw = argv[i]
        local key, value = raw:match("^%-%-([%w_%-]+)=(.*)$")
        if not key then
            key = raw:match("^%-%-([%w_%-]+)$")
            local nextArg = argv[i + 1]
            if key and key:lower() ~= "test" and key:lower() ~= "self"
                and key:lower() ~= "help" and nextArg and not nextArg:match("^%-%-") then
                value = nextArg
                i = i + 1
            end
        end
        if not key then
            error("Unrecognized argument: " .. raw .. "\n\n" .. USAGE, 0)
        end
        if value then
            value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        end
        args[key:lower()] = value or true
        i = i + 1
    end
    return args
end

--[[/hbdoc
\function main
\brief Runs the command-line documentation build.
\details Selects source files, applies output options, and reports the build
summary.
]]
local function main(argv)
    local args = parseArgs(argv)
    if args.help then
        io.write(USAGE)
        return
    end
    if args.include == true or args.sharedcss == true or args.images == true or args.out == true then
        error("--include, --sharedcss, --images and --out each need a value\n\n" .. USAGE, 0)
    end
    if args.self and (args.include or args.test) then
        error("--self cannot be combined with --include or --test\n\n" .. USAGE, 0)
    end

    local files
    if args.self then
        files = { "hbDoc/hbDoc.lua" }
    elseif args.include then
        files = hbDoc.resolveIncludeFile(args.include)
    elseif args.test then
        files = listFiles("test/src", ".cpp")
    else
        io.stderr:write(USAGE)
        os.exit(1)
    end
    assert(#files > 0, "The include rules matched no source files")

    local outDir = args.out or (args.test and "test/docs" or (args.self and "hbDoc/docs" or "docs"))
    local imageDir = args.images or (args.test and "test/docs_res/img" or (not args.self and "docs_res/img"))
    local parsed = hbDoc.build({
        files = files,
        outDir = outDir,
        sharedCss = args.sharedcss,
        imageDir = imageDir,
    })
    print(("Documented %d class(es), %d struct(s), %d function(s) and %d macro(s) from %d file(s) into %s/"):format(
        #parsed.classes, #parsed.structs, #parsed.funcs, #parsed.macros, #files, outDir))
end

-- Run only when executed directly (not when require()d).
if arg and not pcall(debug.getlocal, 4, 1) then
    local ok, err = pcall(main, arg)
    if not ok then
        io.stderr:write(tostring(err), "\n")
        os.exit(1)
    end
end

return hbDoc