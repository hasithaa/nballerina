import wso2/nballerina.err;

type Token SingleCharDelim|MultiCharDelim|Keyword|VariableLengthToken;

const IDENTIFIER = 0;
const DECIMAL_NUMBER = 1;
const STRING_LITERAL = 2;
const BOOLEAN_LITERAL = 3;

// Use string for DECIMAL_NUMBER so we don't get overflow on -int:MAX_VALUE
type VariableLengthToken [IDENTIFIER, string]|[DECIMAL_NUMBER, string]|[STRING_LITERAL, string];

// Some of these are not yet used by the grammar
type SingleCharDelim ";" | "+" | "-" | "*" |"(" | ")" | "[" | "]" | "{" | "}" | "<" | ">" | "?" | "&" | "|" | ":" | "," | "/" | "%" | "=";
type MultiCharDelim "{|" | "|}" | "...";
type Keyword
    "any"
    | "boolean"
    | "byte"
    | "const"
    | "decimal"
    | "error"
    | "false"
    | "float"
    | "function"
    | "handle"
    | "int"
    | "json"
    | "map"
    | "never"
    | "readonly"
    | "record"
    | "return"
    | "returns"
    | "string"
    | "true"
    | "type"
    | "typedesc"
    | "xml"
    | "if"
    | "else"
    | "while"
    | "continue"
    | "break"
    ;

const WS = "\n\r\t ";
const LOWER = "abcdefghijklmnopqrstuvwxyz";
const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const DIGIT = "0123456789";
const string ALPHA = LOWER + UPPER;
const string IDENT = ALPHA + DIGIT + "_";

// JBUG cannot use string:Char #30735
type Char string;

type StringIterator object {
    public isolated function next() returns record {|
        Char value;
    |}?;
};

final readonly & map<Char> ESCAPES = {
    "\\": "\\",
    "\"": "\"",
    "n": "\n",
    "r": "\r",
    "t": "\t"
};

class Tokenizer {
    Token? cur = ();
    // The index in `str` of the first character of `cur`
    private int startIndex = 0;
    // Index of character starting line on which startPos occurs
    private int lineStartIndex = 0;
    // Line number of line starting at lineStartIndex
    private int lineNumber = 1;
    private final string str;

    private final StringIterator iter;
    private Char? ungot = ();
    // Number of characters returned by `iter`
    private int nextCount = 0;
   

    function init(string str) {
        self.iter = str.iterator();
        self.str = str;
    }
   
    // Moves to next token.record
    // Current token is () if there is no next token
    function advance() returns err:Syntax? {
        self.cur = check self.next();
    }

    function current() returns Token? {
        return self.cur;
    }

    function currentPos() returns err:Position {
        return {
            lineNumber: self.lineNumber,
            indexInLine: self.startIndex - self.lineStartIndex
        };
    }

    private function next() returns Token?|err:Syntax {
        // This loops in order to skip over comments
        while true {
            Char? ch = self.startToken();
            if ch is () {
                return ();
            }
            else if ch == "/" {
                ch = self.getc();
                if ch == "/" {
                    // Skip the comment and loop
                    while true {
                        ch = self.getc();
                        if ch is () {
                            break;
                        }
                        else if self.isLineTerminator(ch) {
                            // handle line counting in startToken
                            self.ungetc(ch);
                            break;
                        }
                    }
                    continue;
                }
                else if !(ch is ()) {
                    self.ungetc(ch);
                }
                return "/";
            }
            // Need to do mult-char delims before single-char delims.        
            else if ch == "{" {
                ch = self.getc();
                if ch == "|" {
                    return "{|";
                }
                else if !(ch is ()) {
                    self.ungetc(ch);
                }
                return "{";
            }
            else if ch == "|" {
                ch = self.getc();
                if ch == "}" {
                    return "|}";
                }
                else if !(ch is ()) {
                    self.ungetc(ch);
                }
                return "|";
            }
            else if ch == "." {
                if self.getc() != "." || self.getc() != "." {
                    break;
                }
                return "...";
            }
            else if ch is SingleCharDelim {
                return ch;
            }
            else if ALPHA.includes(ch) {
                string ident = ch;
                while true {
                    ch = self.getc();
                    if ch is () {
                        break;
                    }
                    else if !IDENT.includes(ch) {
                        self.ungetc(ch);
                        break;
                    }
                    else {
                        ident += ch;
                    }
                }
                if ident is Keyword {
                    return ident;
                }
                return [IDENTIFIER, ident];
            }
            else if DIGIT.includes(ch) {
                string digits = ch;
                while true {
                    ch = self.getc();
                    if ch is () {
                        break;
                    }
                    else if !DIGIT.includes(ch) {
                        self.ungetc(ch);
                        break;
                    }
                    else {
                        digits += ch;
                    }
                }
                return [DECIMAL_NUMBER, digits];
            }
            else if ch == "\"" {
                string content = "";
                while true {
                    ch = self.getc();
                    if ch == "\"" {
                        break;
                    }
                    if ch is () || self.isLineTerminator(ch) {
                        return self.err("missing close quote");
                    }
                    else if ch == "\\" {
                        ch = self.getc();
                        if ch is () {
                            return self.err("missing close quote");
                        }
                        else {
                            ch = ESCAPES[ch];
                            if ch is () {
                                return self.err("bad character after backslash");
                            }
                            else {
                                content += ch;
                            }
                        }
                    }
                    else {
                        content += ch;
                    }
                }
                return [STRING_LITERAL, content];
            }
            else {
               break;
            }
        }
        return self.err("invalid token");
    }
    
    private function isLineTerminator(Char ch) returns boolean {
        return ch == "\n" || ch == "\r";
    }

    // Returns first non white-space character, if any
    // Updates startIndex, lineStartIndex and lineNumber
    private function startToken() returns Char? {
        // the previous character if it ended a line, otherwise ()
        Char? prevCharLineEnd = ();
        while true {
            Char? ch = self.getc();
            if ch is () {
                break;
            }
            else {
                if prevCharLineEnd !== () {
                    // Line terminators are part of the line they terminate
                    // Line numbers increase on the first character of a line
                    self.lineStartIndex = self.getCount() - 1;
                    // For \r\n, the line number will be bumped on the
                    // character after the \n
                    if prevCharLineEnd != "\r" || ch != "\n" {
                        self.lineNumber += 1;
                    }
                }
                if ch == "\n" || ch == "\r" {
                    prevCharLineEnd = ch;
                }
                else if ch == " " || ch == "\t" {
                    prevCharLineEnd = ();
                }
                else {
                    self.startIndex = self.getCount() - 1;
                    return ch;
                }
            }
        }
        self.startIndex = self.getCount();
        return ();
    }


    // number of characters returned by getc and not ungot
    private function getCount() returns int {
        return self.ungot is Char ? self.nextCount - 1 : self.nextCount;
    }

    private function getc() returns Char? {
        Char? ch = self.ungot;
        if ch is () {
            return self.nextc();
        }
        else {
            self.ungot = ();
            return ch;
        }
    }

    private function ungetc(Char ch) {
        // we could support arbitrary numbers of unget, by allowing
        // the ungot string to be longer than 1
        // but we don't need it (yet)
        if self.ungot != () {
            panic error("double ungetc");
        }
        self.ungot = ch;
    }

    private function nextc() returns string? {
        var ret = self.iter.next();
        if ret is () {
            return ();
        }
        else {
            self.nextCount += 1;
            return ret.value;
        }
    }

    function expect(SingleCharDelim|MultiCharDelim|Keyword tok) returns err:Syntax? {
        if self.cur != tok {
            err:Template msg;
            Token? t = self.cur;
            if t is string {
                // JBUG cast #30734
                msg = `expected ${<string>tok}; got ${<string>t}`;
            }
            else {
                msg = `expected ${<string>tok}`;
            }
            return self.err(msg);
        }
        check self.advance();
    }

    function err(err:Message msg) returns err:Syntax {
        return err:syntax(msg, self.currentPos());
    }
}
