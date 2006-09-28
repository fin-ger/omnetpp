/*===============================================================
 * File: ned2.y
 *
 *  Grammar for OMNeT++ NED-2.
 *
 *  Author: Andras Varga
 *
 *=============================================================*/

/*--------------------------------------------------------------*
  Copyright (C) 1992,2005 Andras Varga

  This file is distributed WITHOUT ANY WARRANTY. See the file
  `license' for details on this and other legal matters.
*--------------------------------------------------------------*/

/* Reserved words */
%token IMPORT PACKAGE PROPERTY
%token MODULE SIMPLE NETWORK CHANNEL INTERFACE CHANNELINTERFACE
%token EXTENDS LIKE WITHCPPCLASS
%token TYPES PARAMETERS GATES SUBMODULES CONNECTIONS ALLOWUNCONNECTED
%token DOUBLETYPE INTTYPE STRINGTYPE BOOLTYPE XMLTYPE FUNCTION TYPENAME
%token INPUT_ OUTPUT_ INOUT_
%token IF FOR
%token RIGHTARROW LEFTARROW DBLARROW TO
%token TRUE_ FALSE_ THIS_ DEFAULT CONST_ SIZEOF INDEX_ XMLDOC

/* Other tokens: identifiers, numeric literals, operators etc */
%token NAME INTCONSTANT REALCONSTANT STRINGCONSTANT CHARCONSTANT
%token PLUSPLUS DOUBLEASTERISK
%token EQ NE GE LE
%token AND OR XOR NOT
%token BIN_AND BIN_OR BIN_XOR BIN_COMPL
%token SHIFT_LEFT SHIFT_RIGHT

%token INVALID_CHAR   /* just to generate parse error --VA */

/* Operator precedences (low to high) and associativity */
%left '?' ':'
%left AND OR XOR
%left EQ NE '>' GE '<' LE
%left BIN_AND BIN_OR BIN_XOR
%left SHIFT_LEFT SHIFT_RIGHT
%left '+' '-'
%left '*' '/' '%'
%right '^'
%left UMIN NOT BIN_COMPL

%start nedfile

/* requires at least bison 1.50 (tested with bison 2.1) */
%glr-parser

/* A note about parser error recovery. We only add error recovery rules to
 * toplevel elements. Attempting to add such rules to inner nonterminals (param, gate,
 * submodule, etc) has caused erratic behaviour when the synchronizing token
 * (";" or "}") was missing from the input, because bison executed pretty
 * much random rules during recovery. (For example, if a ";" is missing then the
 * parser may eat up everything into the middle of the next compound module where
 * it finally founds a ";" to synchronize on, and starts shifting tokens on the
 * stack from there, and matches them to rules applicable in that context).
 *
 * The actions in this grammar assume that they're being executed in the order
 * prescribed by the grammar, and don't tolerate that rather random behaviour
 * during which bison recovers from various parse errors.
 */

%{

#include <stdio.h>
#include <stdlib.h>
#include <stack>
#include "nedyydefs.h"
#include "nederror.h"

#define YYDEBUG 1           /* allow debugging */
#define YYDEBUGGING_ON 0    /* turn on/off debugging */

#if YYDEBUG != 0
#define YYERROR_VERBOSE     /* more detailed error messages */
#include <string.h>         /* YYVERBOSE needs it */
#endif

#define yylloc ned2yylloc
#define yyin ned2yyin
#define yyout ned2yyout
#define yyrestart ned2yyrestart
#define yy_scan_string ned2yy_scan_string
#define yy_delete_buffer ned2yy_delete_buffer
extern FILE *yyin;
extern FILE *yyout;
struct yy_buffer_state;
struct yy_buffer_state *yy_scan_string(const char *str);
void yy_delete_buffer(struct yy_buffer_state *);
void yyrestart(FILE *);
int yylex();
void yyerror (const char *s);

#include "nedparser.h"
#include "nedfilebuffer.h"
#include "nedelements.h"
#include "nedutil.h"
#include "nedyylib.h"

static struct NED2ParserState
{
    bool inTypes;
    bool inGroup;
    std::stack<NEDElement *> propertyscope; // top(): where to insert properties as we parse them
    std::stack<NEDElement *> blockscope;    // top(): where to insert parameters, gates, etc
    std::stack<NEDElement *> typescope;     // top(): as blockscope, but ignore submodules and connection channels

    /* tmp flags, used with param, gate and conn */
    int paramType;
    int gateType;
    bool isFunction;
    bool isDefault;
    int subgate;
    std::vector<NEDElement *> propvals; // temporarily collects property values

    /* tmp flags, used with msg fields */
    bool isAbstract;
    bool isReadonly;

    /* NED-II: modules, channels */
    NedFileNode *nedfile;
    CommentNode *comment;
    ImportNode *import;
    PropertyDeclNode *propertydecl;
    ExtendsNode *extends;
    InterfaceNameNode *interfacename;
    NEDElement *component;  // compound/simple module, module interface, channel or channel interface
    ParametersNode *parameters;
    ParamGroupNode *paramgroup;
    ParamNode *param;
    PatternNode *pattern;
    PropertyNode *property;
    PropertyKeyNode *propkey;
    TypesNode *types;
    GatesNode *gates;
    GateGroupNode *gategroup;
    GateNode *gate;
    SubmodulesNode *submods;
    SubmoduleNode *submod;
    ConnectionsNode *conns;
    ConnectionGroupNode *conngroup;
    ConnectionNode *conn;
    ChannelSpecNode *chanspec;
    LoopNode *loop;
    ConditionNode *condition;
} ps;


static void resetParserState()
{
    static NED2ParserState cleanps;
    ps = cleanps;
}

static NED2ParserState globalps;  // for error recovery

static void restoreGlobalParserState()  // for error recovery
{
    ps = globalps;
}

static void assertNonEmpty(std::stack<NEDElement *>& somescope) {
    // for error recovery: STL stack::top() crashes if stack is empty
    if (somescope.empty())
    {
        INTERNAL_ERROR0(NULL, "error during parsing: scope stack empty");
        somescope.push(NULL);
    }
}

%}

%%

/*
 * Top-level components
 */
nedfile
        : packagedeclaration somedefinitions
        | somedefinitions
        ;

somedefinitions
        : somedefinitions definition
        |
        ;

definition
        : import
        | propertydecl
        | fileproperty
        | channeldefinition
        | channelinterfacedefinition
        | simplemoduledefinition
        | compoundmoduledefinition
        | networkdefinition
        | moduleinterfacedefinition
        | ';'

        | channelinterfaceheader error '}'
                { storePos(ps.component, @$); restoreGlobalParserState(); }
        | CHANNELINTERFACE error '}'
                { restoreGlobalParserState(); }
        | simplemoduleheader error '}'
                { storePos(ps.component, @$); restoreGlobalParserState(); }
        | SIMPLE error '}'
                { restoreGlobalParserState(); }
        | compoundmoduleheader error '}'
                { storePos(ps.component, @$); restoreGlobalParserState(); }
        | MODULE error '}'
                { restoreGlobalParserState(); }
        | networkheader error '}'
                { storePos(ps.component, @$); restoreGlobalParserState(); }
        | NETWORK error '}'
                { restoreGlobalParserState(); }
        | moduleinterfaceheader error '}'
                { storePos(ps.component, @$); restoreGlobalParserState(); }
        | INTERFACE error '}'
                { restoreGlobalParserState(); }
        | channelheader error '}'
                { storePos(ps.component, @$); restoreGlobalParserState(); }
        | CHANNEL error '}'
                { restoreGlobalParserState(); }
        ;

packagedeclaration         /* TBD package is currently not supported */
        : PACKAGE packagename ';'
        ; /* no error recovery rule -- see discussion at top */

packagename                /* TBD package is currently not supported */
        : packagename '.' NAME
        | NAME
        ;


/*
 * Import
 */
import
        : IMPORT STRINGCONSTANT ';'
                {
                  ps.import = (ImportNode *)createNodeWithTag(NED_IMPORT, ps.nedfile);
                  ps.import->setFilename(toString(trimQuotes(@2)));
                  storePos(ps.import,@$);
                  storeComments(ps.import,@$);
                }
        ; /* no error recovery rule -- see discussion at top */

/*
 * Property declaration
 */
propertydecl
        : propertydecl_header opt_inline_properties ';'
                { storePos(ps.propertydecl, @$); }
        | propertydecl_header '(' opt_propertydecl_keys ')' opt_inline_properties ';'
                { storePos(ps.propertydecl, @$); }
        ; /* no error recovery rule -- see discussion at top */

propertydecl_header
        : PROPERTY '@' NAME
                {
                  ps.propertydecl = (PropertyDeclNode *)createNodeWithTag(NED_PROPERTY_DECL, ps.nedfile);
                  ps.propertydecl->setName(toString(@3));
                  storeComments(ps.propertydecl,@$);
                }
        | PROPERTY '@' NAME '[' ']'
                {
                  ps.propertydecl = (PropertyDeclNode *)createNodeWithTag(NED_PROPERTY_DECL, ps.nedfile);
                  ps.propertydecl->setName(toString(@3));
                  ps.propertydecl->setIsArray(true);
                  storeComments(ps.propertydecl,@$);
                }
        ;

opt_propertydecl_keys
        : propertydecl_keys
        |
        ;

propertydecl_keys
        : propertydecl_keys ';' propertydecl_key
        | propertydecl_key
        ;

propertydecl_key
        : NAME
                {
                  ps.propkey = (PropertyKeyNode *)createNodeWithTag(NED_PROPERTY_KEY, ps.propertydecl);
                  ps.propkey->setKey(toString(@1));
                  storePos(ps.propkey, @$);
                }
        ;

/*
 * File Property
 */
fileproperty
        : property_namevalue ';'
                { storePos(ps.property, @$); }
        ;

/*
 * Channel
 */
channeldefinition
        : channelheader '{'
                {
                  ps.typescope.push(ps.component);
                  ps.blockscope.push(ps.component);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.component);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
          '}'
                {
                  ps.propertyscope.pop();
                  ps.blockscope.pop();
                  ps.typescope.pop();
                  storeTrailingComment(ps.component,@4);
                  if (np->getStoreSourceFlag())
                      storeComponentSourceCode(ps.component, @$);
                  storePos(ps.component, @$);
                }
        ;

channelheader
        : CHANNEL NAME
                {
                  ps.component = (ChannelNode *)createNodeWithTag(NED_CHANNEL, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile);
                  ((ChannelNode *)ps.component)->setName(toString(@2));
                  storeComments(ps.component,@1,@2);
                }
           opt_inheritance
        | CHANNEL WITHCPPCLASS NAME
                {
                  ps.component = (ChannelNode *)createNodeWithTag(NED_CHANNEL, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile);
                  ((ChannelNode *)ps.component)->setName(toString(@3));
                  ((ChannelNode *)ps.component)->setIsWithcppclass(true);
                  storeComments(ps.component,@1,@3);
                }
           opt_inheritance
        ;

opt_inheritance
        :
        | EXTENDS extendsname
        | LIKE likenames
        | EXTENDS extendsname LIKE likenames
        ;

extendsname
        : NAME
                {
                  ps.extends = (ExtendsNode *)createNodeWithTag(NED_EXTENDS, ps.component);
                  ps.extends->setName(toString(@1));
                  storePos(ps.extends, @$);
                }
        ;

likenames
        : likenames ',' likename
        | likename
        ;

likename
        : NAME
                {
                  ps.interfacename = (InterfaceNameNode *)createNodeWithTag(NED_INTERFACE_NAME, ps.component);
                  ps.interfacename->setName(toString(@1));
                  storePos(ps.interfacename, @$);
                }
        ;

/*
 * Channel Interface
 */
channelinterfacedefinition
        : channelinterfaceheader '{'
                {
                  ps.typescope.push(ps.component);
                  ps.blockscope.push(ps.component);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.component);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
          '}'
                {
                  ps.propertyscope.pop();
                  ps.blockscope.pop();
                  ps.typescope.pop();
                  storeTrailingComment(ps.component,@4);
                  if (np->getStoreSourceFlag())
                      storeComponentSourceCode(ps.component, @$);
                  storePos(ps.component, @$);
                }
        ;

channelinterfaceheader
        : CHANNELINTERFACE NAME
                {
                  ps.component = (ChannelInterfaceNode *)createNodeWithTag(NED_CHANNEL_INTERFACE, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile);
                  ((ChannelInterfaceNode *)ps.component)->setName(toString(@2));
                  storeComments(ps.component,@1,@2);
                }
           opt_interfaceinheritance
        ;

opt_interfaceinheritance
        : EXTENDS extendsnames
        |
        ;

extendsnames
        : extendsnames ',' extendsname
        | extendsname
        ;

/*
 * Simple module
 */
simplemoduledefinition
        : simplemoduleheader '{'
                {
                  ps.typescope.push(ps.component);
                  ps.blockscope.push(ps.component);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.component);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
            opt_gateblock
          '}'
                {
                  ps.propertyscope.pop();
                  ps.blockscope.pop();
                  ps.typescope.pop();
                  storeTrailingComment(ps.component,@6);
                  if (np->getStoreSourceFlag())
                      storeComponentSourceCode(ps.component, @$);
                  storePos(ps.component, @$);
                }
        ;

simplemoduleheader
        : SIMPLE NAME
                {
                  ps.component = (SimpleModuleNode *)createNodeWithTag(NED_SIMPLE_MODULE, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile );
                  ((SimpleModuleNode *)ps.component)->setName(toString(@2));
                  storeComments(ps.component,@1,@2);
                }
          opt_inheritance
        ;

/*
 * Module
 */
compoundmoduledefinition
        : compoundmoduleheader '{'
                {
                  ps.typescope.push(ps.component);
                  ps.blockscope.push(ps.component);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.component);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
            opt_gateblock
            opt_typeblock
            opt_submodblock
            opt_connblock
          '}'
                {
                  ps.propertyscope.pop();
                  ps.blockscope.pop();
                  ps.typescope.pop();
                  storeTrailingComment(ps.component,@9);
                  if (np->getStoreSourceFlag())
                      storeComponentSourceCode(ps.component, @$);
                  storePos(ps.component, @$);
                }
        ;

compoundmoduleheader
        : MODULE NAME
                {
                  ps.component = (CompoundModuleNode *)createNodeWithTag(NED_COMPOUND_MODULE, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile );
                  ((CompoundModuleNode *)ps.component)->setName(toString(@2));
                  storeComments(ps.component,@1,@2);
                }
          opt_inheritance
        ;

/*
 * Network
 */
networkdefinition
        : networkheader '{'
                {
                  ps.typescope.push(ps.component);
                  ps.blockscope.push(ps.component);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.component);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
            opt_gateblock
            opt_typeblock
            opt_submodblock
            opt_connblock
          '}'
                {
                  ps.propertyscope.pop();
                  ps.blockscope.pop();
                  ps.typescope.pop();
                  storeTrailingComment(ps.component,@5);
                  if (np->getStoreSourceFlag())
                      storeComponentSourceCode(ps.component, @$);
                  storePos(ps.component, @$);
                }
        ;

networkheader
        : NETWORK NAME
                {
                  ps.component = (CompoundModuleNode *)createNodeWithTag(NED_COMPOUND_MODULE, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile );
                  ((CompoundModuleNode *)ps.component)->setName(toString(@2));
                  ((CompoundModuleNode *)ps.component)->setIsNetwork(true);
                  storeComments(ps.component,@1,@2);
                }
          opt_inheritance
        ;

/*
 * Module Interface
 */
moduleinterfacedefinition
        : moduleinterfaceheader '{'
                {
                  ps.typescope.push(ps.component);
                  ps.blockscope.push(ps.component);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.component);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
            opt_gateblock
          '}'
                {
                  ps.propertyscope.pop();
                  ps.blockscope.pop();
                  ps.typescope.pop();
                  storeTrailingComment(ps.component,@6);
                  if (np->getStoreSourceFlag())
                      storeComponentSourceCode(ps.component, @$);
                  storePos(ps.component, @$);
                }
        ;

moduleinterfaceheader
        : INTERFACE NAME
                {
                  ps.component = (ModuleInterfaceNode *)createNodeWithTag(NED_MODULE_INTERFACE, ps.inTypes ? (NEDElement *)ps.types : (NEDElement *)ps.nedfile);
                  ((ModuleInterfaceNode *)ps.component)->setName(toString(@2));
                  storeComments(ps.component,@1,@2);
                }
           opt_interfaceinheritance
        ;

/*
 * Parameters
 */
opt_paramblock
        : opt_params   /* "parameters" keyword is optional */
                {
                  storePos(ps.parameters, @$);
                  if (!ps.parameters->getFirstChild()) { // delete "parameters" element if empty
                      ps.parameters->getParent()->removeChild(ps.parameters);
                      delete ps.parameters;
                  }
                }
        | PARAMETERS ':'
                {
                  ps.parameters->setIsImplicit(false);
                }
          opt_params
                { storePos(ps.parameters, @$); }
        ;

opt_params
        : params
        |
        ;

params
        : params paramsitem
        | paramsitem
        ;

paramsitem
        : param
        | paramgroup
        | property
        ;

paramgroup
        : opt_condition '{'
                {
                    ps.paramgroup = (ParamGroupNode *)createNodeWithTag(NED_PARAM_GROUP, ps.parameters);
                    if (ps.inGroup)
                       np->getErrors()->add(ps.paramgroup,"nested parameter groups are not allowed");
                    storeComments(ps.paramgroup,@1,@2);
                    ps.inGroup = true;
                }
          params '}'
                {
                    ps.inGroup = false;
                    if ($1)
                        ps.paramgroup->appendChild($1); // append optional condition
                    storePos(ps.paramgroup, @$);
                }
        ;

param
        : param_typenamevalue
                {
                  ps.propertyscope.push(ps.param);
                }
          opt_inline_properties opt_condition ';'
                {
                  ps.propertyscope.pop();
                  if (ps.inGroup && $4)
                      np->getErrors()->add(ps.param,"conditional parameters inside parameter/property groups are not allowed");
                  if ($4 && ps.param->getType()!=NED_PARTYPE_NONE)
                      np->getErrors()->add(ps.param,"parameter declaration cannot be conditional");
                  if ($4)
                      ps.param->appendChild($4); // append optional condition
                  storePos(ps.param, @$);
                  storeComments(ps.param,@$);
                }
        | pattern_value
                {
                  ps.propertyscope.push(ps.pattern);
                }
          opt_inline_properties opt_condition ';'
                {
                  ps.propertyscope.pop();
                  if (ps.inGroup && $4)
                       np->getErrors()->add(ps.pattern,"conditional parameters inside parameter/property groups are not allowed");
                  if ($4)
                      ps.pattern->appendChild($4); // append optional condition
                  storePos(ps.pattern, @$);
                  storeComments(ps.param,@$);
                }
        ; /* no error recovery rule -- see discussion at top */

/*
 * Parameter
 */
param_typenamevalue
        : paramtype opt_function NAME
                {
                  ps.param = addParameter(ps.inGroup ? (NEDElement *)ps.paramgroup : (NEDElement *)ps.parameters, @3);
                  ps.param->setType(ps.paramType);
                  ps.param->setIsFunction(ps.isFunction);
                }
        | paramtype opt_function NAME '=' paramvalue
                {
                  ps.param = addParameter(ps.inGroup ? (NEDElement *)ps.paramgroup : (NEDElement *)ps.parameters, @3);
                  ps.param->setType(ps.paramType);
                  ps.param->setIsFunction(ps.isFunction);
                  addExpression(ps.param, "value",@5,$5);
                  ps.param->setIsDefault(ps.isDefault);
                }
        | NAME '=' paramvalue
                {
                  ps.param = addParameter(ps.inGroup ? (NEDElement *)ps.paramgroup : (NEDElement *)ps.parameters, @1);
                  addExpression(ps.param, "value",@3,$3);
                  ps.param->setIsDefault(ps.isDefault);
                }
        | NAME
                {
                  ps.param = addParameter(ps.inGroup ? (NEDElement *)ps.paramgroup : (NEDElement *)ps.parameters, @1);
                }
        | TYPENAME '=' paramvalue  /* this is to assign module type with the "<> like Foo" syntax */
                {
                  ps.param = addParameter(ps.inGroup ? (NEDElement *)ps.paramgroup : (NEDElement *)ps.parameters, @1);
                  addExpression(ps.param, "value",@3,$3);
                  ps.param->setIsDefault(ps.isDefault);
                }
        ;

pattern_value
        : '/' pattern '/' '=' paramvalue
                {
                  ps.pattern = (PatternNode *)createNodeWithTag(NED_PATTERN, ps.inGroup ? (NEDElement *)ps.paramgroup : (NEDElement *)ps.parameters);
                  ps.pattern->setPattern(toString(@2));
                  addExpression(ps.pattern, "value",@5,$5);
                  ps.pattern->setIsDefault(ps.isDefault);
                }
        ;

paramtype
        : DOUBLETYPE
                { ps.paramType = NED_PARTYPE_DOUBLE; }
        | INTTYPE
                { ps.paramType = NED_PARTYPE_INT; }
        | STRINGTYPE
                { ps.paramType = NED_PARTYPE_STRING; }
        | BOOLTYPE
                { ps.paramType = NED_PARTYPE_BOOL; }
        | XMLTYPE
                { ps.paramType = NED_PARTYPE_XML; }
        ;

opt_function
        : FUNCTION
                { ps.isFunction = true; }
        |
                { ps.isFunction = false; }
        ;

paramvalue
        : expression
                { $$ = $1; ps.isDefault = false; }
        | DEFAULT '(' expression ')'
                { $$ = $3; ps.isDefault = true; }
        ;

opt_inline_properties
        : inline_properties
        |
        ;

inline_properties
        : inline_properties property_namevalue
        | property_namevalue
        ;

pattern /* this attempts to capture inifile-like patterns */
        : pattern pattern_elem
        | pattern_elem
        ;

pattern_elem
        : '.'
        | '*'
        | '?'
        | DOUBLEASTERISK
        | NAME
        | INTCONSTANT
        | TO
        | '[' pattern ']'
        | '{' pattern '}'
        /* allow reserved words in patterns as well */
        | IMPORT | PACKAGE | PROPERTY
        | MODULE | SIMPLE | NETWORK | CHANNEL | INTERFACE | CHANNELINTERFACE
        | EXTENDS | LIKE | WITHCPPCLASS
        | DOUBLETYPE | INTTYPE | STRINGTYPE | BOOLTYPE | XMLTYPE | FUNCTION | TYPENAME
        | INPUT_ | OUTPUT_ | INOUT_ | IF | FOR
        | TYPES | PARAMETERS | GATES | SUBMODULES | CONNECTIONS | ALLOWUNCONNECTED
        | TRUE_ | FALSE_ | THIS_ | DEFAULT | CONST_ | SIZEOF | INDEX_ | XMLDOC
        ;

/*
 * Property
 */
property
        : property_namevalue opt_condition ';'
                {
                  if (ps.inGroup && $2)
                       np->getErrors()->add(ps.param,"conditional properties inside parameter/property groups are not allowed");
                  if ($2)
                      ps.property->appendChild($2); // append optional condition
                  storePos(ps.property, @$);
                  storeComments(ps.property,@$);
                }
        ; /* no error recovery rule -- see discussion at top */

property_namevalue
        : property_name
        | property_name '(' opt_property_keys ')'
        ;

property_name
        : '@' NAME
                {
                  assertNonEmpty(ps.propertyscope);
                  ps.property = addProperty(ps.propertyscope.top(), toString(@2));
                  ps.propvals.clear(); // just to be safe
                }
        | '@' NAME '[' NAME ']'
                {
                  assertNonEmpty(ps.propertyscope);
                  ps.property = addProperty(ps.propertyscope.top(), toString(@2));
                  ps.property->setIndex(toString(@4));
                  ps.propvals.clear(); // just to be safe
                }
        ;

opt_property_keys
        : property_keys  /* can't allow epsilon rule here, because @foo() would result in "ambiguous syntax" :( */
        ;

property_keys
        : property_keys ';' property_key
        | property_key
        ;

property_key
        : NAME '=' property_values
                {
                  ps.propkey = (PropertyKeyNode *)createNodeWithTag(NED_PROPERTY_KEY, ps.property);
                  ps.propkey->setKey(toString(@1));
                  for (int i=0; i<ps.propvals.size(); i++)
                      ps.propkey->appendChild(ps.propvals[i]);
                  ps.propvals.clear();
                  storePos(ps.propkey, @$);
                }
        | property_values
                {
                  ps.propkey = (PropertyKeyNode *)createNodeWithTag(NED_PROPERTY_KEY, ps.property);
                  ps.propkey->appendChild($1);
                  for (int i=0; i<ps.propvals.size(); i++)
                      ps.propkey->appendChild(ps.propvals[i]);
                  ps.propvals.clear();
                  storePos(ps.propkey, @$);
                }
        ;

property_values
        : property_values ',' property_value
                { ps.propvals.push_back($3); }
        | property_value
                { ps.propvals.push_back($1); }
        ;

property_value
        : NAME
                { $$ = createLiteral(NED_CONST_STRING, @1, @1); }
        | '$' NAME
                { $$ = createLiteral(NED_CONST_STRING, @$, @$); }
        | STRINGCONSTANT
                { $$ = createLiteral(NED_CONST_STRING, trimQuotes(@1), @1); }
        | TRUE_
                { $$ = createLiteral(NED_CONST_BOOL, @1, @1); }
        | FALSE_
                { $$ = createLiteral(NED_CONST_BOOL, @1, @1); }
        | INTCONSTANT
                { $$ = createLiteral(NED_CONST_INT, @1, @1); }
        | REALCONSTANT
                { $$ = createLiteral(NED_CONST_DOUBLE, @1, @1); }
        | quantity
                { $$ = createQuantity(toString(@1)); }
        | '-'  /* antivalue ("remove existing value from this position") */
                { $$ = createLiteral(NED_CONST_SPEC, @1, @1); }
        |  /* nothing (no value) */
                {
                  LiteralNode *node = (LiteralNode *)createNodeWithTag(NED_LITERAL);
                  node->setType(NED_CONST_SPEC); // and leave both value and text at ""
                  $$ = node;
                }
        ;

/*
 * Gates
 */
opt_gateblock
        : gateblock
        |
        ;

gateblock
        : GATES ':'
                {
                  assertNonEmpty(ps.blockscope);
                  ps.gates = (GatesNode *)createNodeWithTag(NED_GATES, ps.blockscope.top());
                  storeComments(ps.gates,@1,@2);
                }
          opt_gates
                {
                  storePos(ps.gates, @$);
                }
        ;

opt_gates
        : gates
        |
        ;

gates
        : gates gatesitem
                {
                  storeComments(ps.gate,@2);
                }
        | gatesitem
                {
                  storeComments(ps.gate,@1);
                }
        ;

gatesitem
        : gategroup
        | gate
        ;

gategroup
        : opt_condition '{'
                {
                    ps.gategroup = (GateGroupNode *)createNodeWithTag(NED_GATE_GROUP, ps.gates);
                    if (ps.inGroup)
                       np->getErrors()->add(ps.gategroup,"nested gate groups are not allowed");
                    ps.inGroup = true;
                }
          gates '}'
                {
                    ps.inGroup = false;
                    if ($1)
                        ps.gategroup->appendChild($1); // append optional condition
                    storePos(ps.gategroup, @$);
                }
        ;

/*
 * Gate
 */
gate
        : gate_typenamesize
                {
                  ps.propertyscope.push(ps.gate);
                }
          opt_inline_properties opt_condition ';'
                {
                  ps.propertyscope.pop();
                  if (ps.inGroup && $4)
                       np->getErrors()->add(ps.gate,"conditional gates inside gate groups are not allowed");
                  if ($4 && ps.gate->getType()!=NED_GATETYPE_NONE)
                      np->getErrors()->add(ps.gate,"gate declaration cannot be conditional");
                  if ($4)
                      ps.gate->appendChild($4); // append optional condition
                  storePos(ps.gate, @$);
                }
        ; /* no error recovery rule -- see discussion at top */

gate_typenamesize
        : gatetype NAME
                {
                  ps.gate = addGate(ps.inGroup ? (NEDElement *)ps.gategroup : (NEDElement *)ps.gates, @2);
                  ps.gate->setType(ps.gateType);
                }
        | gatetype NAME '[' ']'
                {
                  ps.gate = addGate(ps.inGroup ? (NEDElement *)ps.gategroup : (NEDElement *)ps.gates, @2);
                  ps.gate->setType(ps.gateType);
                  ps.gate->setIsVector(true);
                }
        | gatetype NAME vector
                {
                  ps.gate = addGate(ps.inGroup ? (NEDElement *)ps.gategroup : (NEDElement *)ps.gates, @2);
                  ps.gate->setType(ps.gateType);
                  ps.gate->setIsVector(true);
                  addVector(ps.gate, "vector-size",@3,$3);
                }
        | NAME
                {
                  ps.gate = addGate(ps.inGroup ? (NEDElement *)ps.gategroup : (NEDElement *)ps.gates, @1);
                }
        | NAME '[' ']'
                {
                  ps.gate = addGate(ps.inGroup ? (NEDElement *)ps.gategroup : (NEDElement *)ps.gates, @1);
                  ps.gate->setIsVector(true);
                }
        | NAME vector
                {
                  ps.gate = addGate(ps.inGroup ? (NEDElement *)ps.gategroup : (NEDElement *)ps.gates, @1);
                  ps.gate->setIsVector(true);
                  addVector(ps.gate, "vector-size",@2,$2);
                }
        ;

gatetype
        : INPUT_
                { ps.gateType = NED_GATETYPE_INPUT; }
        | OUTPUT_
                { ps.gateType = NED_GATETYPE_OUTPUT; }
        | INOUT_
                { ps.gateType = NED_GATETYPE_INOUT; }
        ;

/*
 * Local Types
 */
opt_typeblock
        : typeblock
        |
        ;

typeblock
        : TYPES ':'
                {
                  assertNonEmpty(ps.blockscope);
                  ps.types = (TypesNode *)createNodeWithTag(NED_TYPES, ps.blockscope.top());
                  storeComments(ps.types,@1,@2);
                  if (ps.inTypes)
                     np->getErrors()->add(ps.paramgroup,"more than one level of type nesting is not allowed");
                  ps.inTypes = true;
                }
           opt_localtypes
                {
                  ps.inTypes = false;
                  storePos(ps.types, @$);
                }
        ;

opt_localtypes
        : localtypes
        |
        ;

localtypes
        : localtypes localtype
        | localtype
        ;

localtype
        : propertydecl
        | channeldefinition
        | channelinterfacedefinition
        | simplemoduledefinition
        | compoundmoduledefinition
        | networkdefinition
        | moduleinterfacedefinition
        | ';'
        ;

/*
 * Submodules
 */
opt_submodblock
        : submodblock
        |
        ;

submodblock
        : SUBMODULES ':'
                {
                  assertNonEmpty(ps.blockscope);
                  ps.submods = (SubmodulesNode *)createNodeWithTag(NED_SUBMODULES, ps.blockscope.top());
                  storeComments(ps.submods,@1,@2);
                }
          opt_submodules
                {
                  storePos(ps.submods, @$);
                }
        ;

opt_submodules
        : submodules
        |
        ;

submodules
        : submodules submodule
        | submodule
        ;

submodule
        : submoduleheader ';'
                {
                  storeComments(ps.submod,@1,@2);
                  storePos(ps.submod, @$);
                }
        | submoduleheader '{'
                {
                  ps.blockscope.push(ps.submod);
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.submod);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                  storeComments(ps.submod,@1,@2);
                }
          opt_paramblock
          opt_gateblock
          '}' opt_semicolon
                {
                  ps.blockscope.pop();
                  ps.propertyscope.pop();
                  storePos(ps.submod, @$);
                }
        ; /* no error recovery rule -- see discussion at top */

submoduleheader
        : submodulename ':' NAME
                {
                  ps.submod->setType(toString(@3));
                }
        | submodulename ':' likeparam LIKE NAME
                {
                  addLikeParam(ps.submod, "like-param", @3, $3);
                  ps.submod->setLikeType(toString(@5));
                }
        | submodulename ':' likeparam LIKE '*'
                {
                  addLikeParam(ps.submod, "like-param", @3, $3);
                  ps.submod->setLikeAny(true);
                }
        ;

submodulename
        : NAME
                {
                  ps.submod = (SubmoduleNode *)createNodeWithTag(NED_SUBMODULE, ps.submods);
                  ps.submod->setName(toString(@1));
                }
        |  NAME vector
                {
                  ps.submod = (SubmoduleNode *)createNodeWithTag(NED_SUBMODULE, ps.submods);
                  ps.submod->setName(toString(@1));
                  addVector(ps.submod, "vector-size",@2,$2);
                }
        ;

likeparam
        : '<' '>'
                { $$ = NULL; }
        | '<' '@' NAME '>'
                { $$ = NULL; }
        | '<' thisqualifier '.' '@' NAME '>'
                { $$ = NULL; }
        | '<' expression '>' /* XXX this expression is the source of one shift-reduce conflict because it may contain '>' */
                { $$ = $2; }
        ;

thisqualifier
        : THIS_
        | NAME
                { np->getErrors()->add(NULL,"invalid property qualifier `%s', only `this' is allowed here", toString(@1)); }
        | NAME vector
                { np->getErrors()->add(NULL,"invalid property qualifier `%s', only `this' is allowed here", toString(@1)); }
        ;


/*
 * Connections
 */
opt_connblock
        : connblock
        |
        ;

connblock
        : CONNECTIONS ALLOWUNCONNECTED ':'
                {
                  assertNonEmpty(ps.blockscope);
                  ps.conns = (ConnectionsNode *)createNodeWithTag(NED_CONNECTIONS, ps.blockscope.top());
                  ps.conns->setAllowUnconnected(true);
                  storeComments(ps.conns,@1,@3);
                }
          opt_connections
                {
                  storePos(ps.conns, @$);
                }
        | CONNECTIONS ':'
                {
                  assertNonEmpty(ps.blockscope);
                  ps.conns = (ConnectionsNode *)createNodeWithTag(NED_CONNECTIONS, ps.blockscope.top());
                  storeComments(ps.conns,@1,@2);
                }
          opt_connections
                {
                  storePos(ps.conns, @$);
                }
        ;

opt_connections
        : connections
        |
        ;

connections
        : connections connectionsitem
        | connectionsitem
        ;

connectionsitem
        : connectiongroup
        | connection opt_loops_and_conditions ';'
                {
                  ps.chanspec = (ChannelSpecNode *)ps.conn->getFirstChildWithTag(NED_CHANNEL_SPEC);
                  if (ps.chanspec)
                      ps.conn->appendChild(ps.conn->removeChild(ps.chanspec)); // move channelspec to conform DTD
                  if ($2) {
                      transferChildren($2, ps.conn);
                      delete $2;
                  }
                  storePos(ps.conn, @$);
                  storeComments(ps.conn,@$);
                }
        ; /* no error recovery rule -- see discussion at top */

connectiongroup
        : opt_loops_and_conditions '{'
                {
                  //FIXME error if already in group (ps.inGroup)? otherwise we can't restore ps.conngroup....
                  ps.conngroup = (ConnectionGroupNode *)createNodeWithTag(NED_CONNECTION_GROUP, ps.conns);
                  if ($1) {
                      transferChildren($1, ps.conngroup);
                      delete $1;
                  }
                  ps.inGroup = true;
                }
          connections '}' opt_semicolon
                {
                  ps.inGroup = false;
                  storePos(ps.conngroup,@$);
                  storeComments(ps.conngroup,@$);
                }
        ;

opt_loops_and_conditions
        : loops_and_conditions
                { $$ = $1; }
        |
                { $$ = NULL; }
        ;

loops_and_conditions
        : loops_and_conditions ',' loop_or_condition
                {
                  $1->appendChild($3);
                  $$ = $1;
                }
        | loop_or_condition
                {
                  $$ = new UnknownNode();
                  $$->appendChild($1);
                }
        ;

loop_or_condition
        : loop
        | condition
        ;

loop
        : FOR NAME '=' expression TO expression
                {
                  ps.loop = (LoopNode *)createNodeWithTag(NED_LOOP);
                  ps.loop->setParamName( toString(@2) );
                  addExpression(ps.loop, "from-value",@4,$4);
                  addExpression(ps.loop, "to-value",@6,$6);
                  storePos(ps.loop, @$);
                  $$ = ps.loop;
                }
        ;

/*
 * Connection
 */
connection
        : leftgatespec RIGHTARROW rightgatespec
                {
                  ps.conn->setArrowDirection(NED_ARROWDIR_L2R);
                }
        | leftgatespec RIGHTARROW channelspec RIGHTARROW rightgatespec
                {
                  ps.conn->setArrowDirection(NED_ARROWDIR_L2R);
                }
        | leftgatespec LEFTARROW rightgatespec
                {
                  swapConnection(ps.conn);
                  ps.conn->setArrowDirection(NED_ARROWDIR_R2L);
                }
        | leftgatespec LEFTARROW channelspec LEFTARROW rightgatespec
                {
                  swapConnection(ps.conn);
                  ps.conn->setArrowDirection(NED_ARROWDIR_R2L);
                }
        | leftgatespec DBLARROW rightgatespec
                {
                  ps.conn->setArrowDirection(NED_ARROWDIR_BIDIR);
                }
        | leftgatespec DBLARROW channelspec DBLARROW rightgatespec
                {
                  ps.conn->setArrowDirection(NED_ARROWDIR_BIDIR);
                }
        ;

leftgatespec
        : leftmod '.' leftgate opt_subgate
                { ps.conn->setSrcGateSubg(ps.subgate); }
        | parentleftgate opt_subgate
                { ps.conn->setSrcGateSubg(ps.subgate); }
        ;

leftmod
        : NAME vector
                {
                  ps.conn = (ConnectionNode *)createNodeWithTag(NED_CONNECTION, ps.inGroup ? (NEDElement*)ps.conngroup : (NEDElement*)ps.conns );
                  ps.conn->setSrcModule( toString(@1) );
                  addVector(ps.conn, "src-module-index",@2,$2);
                }
        | NAME
                {
                  ps.conn = (ConnectionNode *)createNodeWithTag(NED_CONNECTION, ps.inGroup ? (NEDElement*)ps.conngroup : (NEDElement*)ps.conns );
                  ps.conn->setSrcModule( toString(@1) );
                }
        ;

leftgate
        : NAME
                {
                  ps.conn->setSrcGate( toString( @1) );
                }
        | NAME vector
                {
                  ps.conn->setSrcGate( toString( @1) );
                  addVector(ps.conn, "src-gate-index",@2,$2);
                }
        | NAME PLUSPLUS
                {
                  ps.conn->setSrcGate( toString( @1) );
                  ps.conn->setSrcGatePlusplus(true);
                }
        ;

parentleftgate
        : NAME
                {
                  ps.conn = (ConnectionNode *)createNodeWithTag(NED_CONNECTION, ps.inGroup ? (NEDElement*)ps.conngroup : (NEDElement*)ps.conns );
                  ps.conn->setSrcModule("");
                  ps.conn->setSrcGate(toString(@1));
                }
        | NAME vector
                {
                  ps.conn = (ConnectionNode *)createNodeWithTag(NED_CONNECTION, ps.inGroup ? (NEDElement*)ps.conngroup : (NEDElement*)ps.conns );
                  ps.conn->setSrcModule("");
                  ps.conn->setSrcGate(toString(@1));
                  addVector(ps.conn, "src-gate-index",@2,$2);
                }
        | NAME PLUSPLUS
                {
                  ps.conn = (ConnectionNode *)createNodeWithTag(NED_CONNECTION, ps.inGroup ? (NEDElement*)ps.conngroup : (NEDElement*)ps.conns );
                  ps.conn->setSrcModule("");
                  ps.conn->setSrcGate(toString(@1));
                  ps.conn->setSrcGatePlusplus(true);
                }
        ;

rightgatespec
        : rightmod '.' rightgate opt_subgate
                { ps.conn->setDestGateSubg(ps.subgate); }
        | parentrightgate opt_subgate
                { ps.conn->setDestGateSubg(ps.subgate); }
        ;

rightmod
        : NAME
                {
                  ps.conn->setDestModule( toString(@1) );
                }
        | NAME vector
                {
                  ps.conn->setDestModule( toString(@1) );
                  addVector(ps.conn, "dest-module-index",@2,$2);
                }
        ;

rightgate
        : NAME
                {
                  ps.conn->setDestGate( toString( @1) );
                }
        | NAME vector
                {
                  ps.conn->setDestGate( toString( @1) );
                  addVector(ps.conn, "dest-gate-index",@2,$2);
                }
        | NAME PLUSPLUS
                {
                  ps.conn->setDestGate( toString( @1) );
                  ps.conn->setDestGatePlusplus(true);
                }
        ;

parentrightgate
        : NAME
                {
                  ps.conn->setDestGate( toString( @1) );
                }
        | NAME vector
                {
                  ps.conn->setDestGate( toString( @1) );
                  addVector(ps.conn, "dest-gate-index",@2,$2);
                }
        | NAME PLUSPLUS
                {
                  ps.conn->setDestGate( toString( @1) );
                  ps.conn->setDestGatePlusplus(true);
                }
        ;

opt_subgate
        : '$' NAME
                {
                  const char *s = toString(@2);
                  if (!strcmp(s,"i"))
                      ps.subgate = NED_SUBGATE_I;
                  else if (!strcmp(s,"o"))
                      ps.subgate = NED_SUBGATE_O;
                  else
                       np->getErrors()->add(NULL,"invalid subgate spec `%s', must be `i' or `o'", toString(@2));
                }
        |
                {  ps.subgate = NED_SUBGATE_NONE; }
        ;

channelspec
        : channelspec_header
        | channelspec_header '{'
                {
                  ps.parameters = (ParametersNode *)createNodeWithTag(NED_PARAMETERS, ps.chanspec);
                  ps.parameters->setIsImplicit(true);
                  ps.propertyscope.push(ps.parameters);
                }
            opt_paramblock
          '}'
                {
                  ps.propertyscope.pop();
                  storePos(ps.chanspec, @$);
                }
        ;


channelspec_header
        :
                {
                  ps.chanspec = (ChannelSpecNode *)createNodeWithTag(NED_CHANNEL_SPEC, ps.conn);
                }
        | NAME
                {
                  ps.chanspec = (ChannelSpecNode *)createNodeWithTag(NED_CHANNEL_SPEC, ps.conn);
                  ps.chanspec->setType(toString(@1));
                }
        | likeparam LIKE NAME
                {
                  ps.chanspec = (ChannelSpecNode *)createNodeWithTag(NED_CHANNEL_SPEC, ps.conn);
                  addLikeParam(ps.chanspec, "like-param", @1, $1);
                  ps.chanspec->setLikeType(toString(@3));
                }
        | likeparam LIKE '*'
                {
                  ps.chanspec = (ChannelSpecNode *)createNodeWithTag(NED_CHANNEL_SPEC, ps.conn);
                  addLikeParam(ps.chanspec, "like-param", @1, $1);
                  ps.chanspec->setLikeAny(true);
                }
        ;

/*
 * Condition
 */
opt_condition
        : condition
           { $$ = $1; }
        |
           { $$ = NULL; }
        ;

condition
        : IF expression
                {
                  ps.condition = (ConditionNode *)createNodeWithTag(NED_CONDITION);
                  addExpression(ps.condition, "condition",@2,$2);
                  storePos(ps.condition, @$);
                  $$ = ps.condition;
                }
        ;

/*
 * Common part
 */
vector
        : '[' expression ']'
                { $$ = $2; }
        ;

expression
        :
          expr
                {
                  if (np->getParseExpressionsFlag()) $$ = createExpression($1);
                }
        | xmldocvalue
                {
                  if (np->getParseExpressionsFlag()) $$ = createExpression($1);
                }
        ;

/*
 * Expressions
 */
/* FIXME TBD: storePos() stuff for expressions */
xmldocvalue
        : XMLDOC '(' stringliteral ',' stringliteral ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction("xmldoc", $3, $5); }
        | XMLDOC '(' stringliteral ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction("xmldoc", $3); }
        ;

expr
        : simple_expr
        | '(' expr ')'
                { $$ = $2; }
        | CONST_ '(' expr ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction("const", $3); }

        | expr '+' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("+", $1, $3); }
        | expr '-' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("-", $1, $3); }
        | expr '*' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("*", $1, $3); }
        | expr '/' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("/", $1, $3); }
        | expr '%' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("%", $1, $3); }
        | expr '^' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("^", $1, $3); }

        | '-' expr
                %prec UMIN
                { if (np->getParseExpressionsFlag()) $$ = unaryMinus($2); }

        | expr EQ expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("==", $1, $3); }
        | expr NE expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("!=", $1, $3); }
        | expr '>' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator(">", $1, $3); }
        | expr GE expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator(">=", $1, $3); }
        | expr '<' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("<", $1, $3); }
        | expr LE expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("<=", $1, $3); }

        | expr AND expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("&&", $1, $3); }
        | expr OR expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("||", $1, $3); }
        | expr XOR expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("##", $1, $3); }

        | NOT expr
                %prec UMIN
                { if (np->getParseExpressionsFlag()) $$ = createOperator("!", $2); }

        | expr BIN_AND expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("&", $1, $3); }
        | expr BIN_OR expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("|", $1, $3); }
        | expr BIN_XOR expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("#", $1, $3); }

        | BIN_COMPL expr
                %prec UMIN
                { if (np->getParseExpressionsFlag()) $$ = createOperator("~", $2); }
        | expr SHIFT_LEFT expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("<<", $1, $3); }
        | expr SHIFT_RIGHT expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator(">>", $1, $3); }
        | expr '?' expr ':' expr
                { if (np->getParseExpressionsFlag()) $$ = createOperator("?:", $1, $3, $5); }

        | NAME '(' ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction(toString(@1)); }
        | NAME '(' expr ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction(toString(@1), $3); }
        | NAME '(' expr ',' expr ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction(toString(@1), $3, $5); }
        | NAME '(' expr ',' expr ',' expr ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction(toString(@1), $3, $5, $7); }
        | NAME '(' expr ',' expr ',' expr ',' expr ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction(toString(@1), $3, $5, $7, $9); }
         ;

simple_expr
        : identifier
        | special_expr
        | literal
        ;

identifier
        : NAME
                { if (np->getParseExpressionsFlag()) $$ = createIdent(@1); }
        | THIS_ '.' NAME
                { if (np->getParseExpressionsFlag()) $$ = createIdent(@3, @1); }
        | NAME '.' NAME
                { if (np->getParseExpressionsFlag()) $$ = createIdent(@3, @1); }
        | NAME vector '.' NAME
                { if (np->getParseExpressionsFlag()) $$ = createIdent(@4, @1, $2); }
        ;

special_expr
        : INDEX_
                { if (np->getParseExpressionsFlag()) $$ = createFunction("index"); }
        | INDEX_ '(' ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction("index"); }
        | SIZEOF '(' identifier ')'
                { if (np->getParseExpressionsFlag()) $$ = createFunction("sizeof", $3); }
        ;

literal
        : stringliteral
        | boolliteral
        | numliteral
        ;

stringliteral
        : STRINGCONSTANT
                { if (np->getParseExpressionsFlag()) $$ = createLiteral(NED_CONST_STRING, trimQuotes(@1), @1); }
        ;

boolliteral
        : TRUE_
                { if (np->getParseExpressionsFlag()) $$ = createLiteral(NED_CONST_BOOL, @1, @1); }
        | FALSE_
                { if (np->getParseExpressionsFlag()) $$ = createLiteral(NED_CONST_BOOL, @1, @1); }
        ;

numliteral
        : INTCONSTANT
                { if (np->getParseExpressionsFlag()) $$ = createLiteral(NED_CONST_INT, @1, @1); }
        | REALCONSTANT
                { if (np->getParseExpressionsFlag()) $$ = createLiteral(NED_CONST_DOUBLE, @1, @1); }
        | quantity
                { if (np->getParseExpressionsFlag()) $$ = createQuantity(toString(@1)); }
        ;

quantity
        : quantity INTCONSTANT NAME
        | quantity REALCONSTANT NAME
        | INTCONSTANT NAME
        | REALCONSTANT NAME
        ;

opt_semicolon
        : ';'
        |
        ;

%%

//----------------------------------------------------------------------
// general bison/flex stuff:
//

NEDElement *doParseNED2(NEDParser *p, const char *nedtext)
{
#if YYDEBUG != 0      /* #if added --VA */
    yydebug = YYDEBUGGING_ON;
#endif

    // reset the lexer
    pos.co = 0;
    pos.li = 1;
    prevpos = pos;

    yyin = NULL;
    yyout = stderr; // not used anyway

    // alloc buffer
    struct yy_buffer_state *handle = yy_scan_string(nedtext);
    if (!handle)
        {np->getErrors()->add(NULL, "unable to allocate work memory"); return false;}

    // create parser state and NEDFileNode
    np = p;
    resetParserState();
    ps.nedfile = new NedFileNode();

    // store file name with slashes always, even on Windows -- neddoc relies on that
    ps.nedfile->setFilename(slashifyFilename(np->getFileName()).c_str());
    ps.nedfile->setVersion("2");

    // store file comment
    storeFileComment(ps.nedfile);

    ps.propertyscope.push(ps.nedfile);

    globalps = ps; // remember this for error recovery

    if (np->getStoreSourceFlag())
        storeSourceCode(ps.nedfile, np->getSource()->getFullTextPos());

    // parse
    int ret;
    try
    {
        ret = yyparse();
    }
    catch (NEDException *e)
    {
        INTERNAL_ERROR1(NULL, "error during parsing: %s", e->errorMessage());
        yy_delete_buffer(handle);
        delete e;
        return 0;
    }

    if (np->getErrors()->empty())
    {
        // more sanity checks
        if (ps.propertyscope.size()!=1 || ps.propertyscope.top()!=ps.nedfile)
            INTERNAL_ERROR0(NULL, "error during parsing: imbalanced propertyscope");
        if (!ps.blockscope.empty() || !ps.typescope.empty())
            INTERNAL_ERROR0(NULL, "error during parsing: imbalanced blockscope or typescope");
    }
    yy_delete_buffer(handle);

    //FIXME TODO: fill in @documentation properties from comments
    return ps.nedfile;
}

void yyerror(const char *s)
{
    // chop newline
    char buf[250];
    strcpy(buf, s);
    if (buf[strlen(buf)-1] == '\n')
        buf[strlen(buf)-1] = '\0';

    np->error(buf, pos.li);
}

