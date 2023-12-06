package gdcompiler;

#if (macro || gdscript_runtime)

//import haxe.macro.Context;
import reflaxe.helpers.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

import haxe.display.Display.MetadataTarget;

import reflaxe.data.ClassVarData;
import reflaxe.data.ClassFuncData;
import reflaxe.data.EnumOptionData;

import reflaxe.DirectToStringCompiler;
import reflaxe.compiler.EverythingIsExprSanitizer;
import reflaxe.helpers.OperatorHelper;

import gdcompiler.config.Define;
import gdcompiler.config.Meta;

import gdcompiler.subcompilers.TypeCompiler;

using reflaxe.helpers.ArrayHelper;
using reflaxe.helpers.BaseTypeHelper;
using reflaxe.helpers.ClassFieldHelper;
using reflaxe.helpers.ModuleTypeHelper;
using reflaxe.helpers.NameMetaHelper;
using reflaxe.helpers.NullableMetaAccessHelper;
using reflaxe.helpers.NullHelper;
using reflaxe.helpers.OperatorHelper;
using reflaxe.helpers.StringBufHelper;
using reflaxe.helpers.SyntaxHelper;
using reflaxe.helpers.TypedExprHelper;
using reflaxe.helpers.TypeHelper;

class GDCompiler extends reflaxe.DirectToStringCompiler {
	/**
		Type compiler.
	**/
	var TComp: TypeCompiler;

	/**
		Keeps track of all the classes that extend from `godot.Node`.
		Important for plugin generation.
	**/
	var pluginNodeClasses: Array<ClassType> = [];

	/**
		Keeps track of all the classes that extend from `godot.Resource`.
		Important for plugin generation.
	**/
	var pluginResourceClasses: Array<ClassType> = [];

	/**
		A stack used to track any overrides to the "self" keyword.
		If empty, "self" will be used.
	**/
	var selfStack: Array<String> = [];

	public function new() {
		super();

		TComp = new TypeCompiler(this);
	}

	/**
		Runs at the start of compilation.
		Generates the bare-bones `HxStaticVars.gd` file.
	**/
	public override function onCompileStart() {
		setExtraFile("HxStaticVars.gd", "extends Node\n\n");
	}

	/**
		Runs at the end of compilation.
		Generates the Godot plugin if `-D generate_godot_plugin` is defined.
	**/
	public override function onCompileEnd() {
		if(Context.defined(Define.GenerateGodotPlugin)) {
			generatePlugin();
		}
	}

	/**
		Generates the Godot plugin for the output GDScript files.
		This is done by generating a `plugin.cfg` file its behavior code in `plugin.gd`.

		(`plugin.gd`'s filename can be changed using `-D godot_plugin_script_name`).
	**/
	function generatePlugin() {
		final getD = (name) -> Context.definedValue(name);

		var pluginGDSource = getD(Define.GodotPluginScriptName) ?? "plugin.gd";

		if(!StringTools.contains(pluginGDSource, ".")) {
			pluginGDSource += ".gd";
		}

		setExtraFile("plugin.cfg", '[plugin]
name="${getD(Define.GodotPluginName) ?? "Reflaxe/GDScript Output"}"
description="${getD(Define.GodotPluginDescription) ?? "Generated by Reflaxe/GDScript"}"
author="${getD(Define.GodotPluginAuthor) ?? ""}"
version="${getD(Define.GodotPluginVersion) ?? ""}"
script="$pluginGDSource"
');

		final enterNodes = pluginNodeClasses.map(function(cls) {
			// Guaranteed to have super class if in `pluginNodeClasses`.
			final args = [
				'"${cls.name}"',
				'"${cls.superClass.trustMe().t.get().name}"',
				'preload("${cls.globalName()}.gd")',
				'preload("${cls.meta.extractStringFromFirstMeta(Meta.Icon) ?? "res://icon.svg"}")'
			];
			return 'add_custom_type(${args.join(", ")})';
		}).join("\n");

		final enterResources = pluginResourceClasses.map(function(cls) {
			// Guaranteed to have super class if in `pluginResourceClasses`.
			final args = [
				'"${cls.name}"',
				'"${cls.superClass.trustMe().t.get().name}"',
				'preload("${cls.globalName()}.gd")',
				'preload("${cls.meta.extractStringFromFirstMeta(Meta.Icon) ?? "res://icon.svg"}")'
			];
			return 'add_custom_type(${args.join(", ")})';
		}).join("\n");

		final exitNodes = pluginNodeClasses.map((cls) -> 'remove_custom_type("${cls.name}")').join("\n");
		final exitResources = pluginResourceClasses.map((cls) -> 'remove_custom_type("${cls.name}")').join("\n");

		function line(s: String) return s.length > 0 ? ("\n\t" + s) : s;

		setExtraFile(pluginGDSource, '@tool
extends EditorPlugin

const AUTOLOAD_NAME = "HxStaticVars"

func _enter_tree():
	add_autoload_singleton(AUTOLOAD_NAME, "HxStaticVars.gd")${line(enterNodes)}${line(enterResources)}

func _exit_tree():
	remove_autoload_singleton(AUTOLOAD_NAME)${line(exitNodes)}${line(exitResources)}
');
	}

	/**
		Returns `true` if the `ClassType` is `godot.Node`.
		
		TODO: Might be obsolete, so maybe delete?
	**/
	function isGodotNode(t: ClassType) {
		return if(t.isExtern && t.pack.length == 1 && t.pack[0] == "godot" && t.name == "Node") {
			true;
		} else if(t.superClass != null) {
			isGodotNode(t.superClass.t.get());
		} else {
			false;
		}
	}

	function extendsFrom(t: ClassType, metadata: String): Bool {
		if(t.superClass == null) {
			return false;
		}

		final parent = t.superClass.t.get();
		if(parent.meta.maybeHas(":generated_godot_api") && parent.meta.maybeHas(metadata)) {
			final entries = parent.meta.maybeExtract(metadata);

			// Check if the first parameter of the metadata is `true`.
			for(e in entries) {
				switch(e.params) {
					case [macro true]: return true;
					case _:
				}
			}
		}

		return extendsFrom(parent, metadata);
	}

	function extendsFromNode(t: ClassType): Bool {
		return extendsFrom(t, ":is_node");
	}

	function extendsFromResource(t: ClassType): Bool {
		return extendsFrom(t, ":is_resource");
	}

	public function compileClassImpl(classType: ClassType, varFields: Array<ClassVarData>, funcFields: Array<ClassFuncData>): Null<String> {
		final variables = [];
		final functions = [];
		final staticVars = [];
		final className = classType.name;
		final isWrapper = classType.hasMeta(Meta.Wrapper);

		var header = new StringBuf();
	
		// @:icon -> @icon
		if(classType.meta.has(Meta.Icon)) {
			final iconPath = classType.meta.extractStringFromFirstMeta(Meta.Icon);
			if(iconPath != null) {
				header.addMulti("@icon(\"", iconPath, "\")");
			} else {
				Context.error("Icon path required.", classType.meta.getFirstPosition(Meta.Icon) ?? classType.pos);
			}
		}

		final clsMeta = compileMetadata(classType.meta, MetadataTarget.Class);
		if(clsMeta != null) {
			header.add(StringTools.trim(clsMeta) + "\n");
		}

		if(isWrapper) { // Wrapper only exists to host code, should not be treated like node itself
			header.add("extends Object\n");
		} else if(classType.superClass != null) {
			header.add("extends " + TComp.compileClassName(classType.superClass.t.get()) + "\n");
		}

		header.addMulti("class_name ", TComp.compileClassName(classType));

		// Add "_GD" to the end of class name for wrapper classes.
		if(isWrapper) {
			header.add("_GD");
		}

		header.add("\n\n");

		// instance vars
		for(v in varFields) {
			final field = v.field;

			if(field.isExtern || field.hasMeta(":extern") || field.hasMeta(":gd_extern")) {
				continue;
			}

			final varName: String = field.meta.extractStringFromFirstMeta(":nativeName") ?? compileVarName(field.name, null, field);

			final e = field.expr();
			final gdScriptVal = if(e != null) {
				compileClassVarExpr(e);
			} else {
				"";
			}
			if(v.isStatic) {
				staticVars.push({ name: varName, expr: gdScriptVal });
			} else {
				final meta = compileMetadata(field.meta, MetadataTarget.ClassField);

				//:onready
				final meta: String = if(field.meta.has(":onready") && isGodotNode(classType)) {
					"@onready " + (meta ?? "");
				} else {
					meta ?? "";
				}

				final declBuffer = new StringBuf();
				declBuffer.addMulti(meta, "var ", varName);

				#if !gdscript_untyped
				final compiledType = TComp.compileType(v.field.type, v.field.pos);
				if(compiledType != null) {
					declBuffer.addMulti(": ", compiledType.trustMe());
				}
				#end

				if(gdScriptVal.length > 0) {
					declBuffer.addMulti(" = ", gdScriptVal);
				}

				variables.push(declBuffer.toString());
			}
		}

		// class functions
		for(f in funcFields) {
			final field = f.field;
			final tfunc = f.tfunc;

			// Let's figure out that name
			final name: String = if(field.name == "new") {
				"_init";
			} else {
				var result = null;
				if(field.hasMeta(":nativeName")) {
					result = field.meta.extractStringFromFirstMeta(":nativeName");
				}
				if(result == null) {
					final varName = compileVarName(field.name);
					
					// Prepend "wrap_" to prevent conflicts with virtuals like "_ready" and "_process".
					if(isWrapper) {
						"wrap_" + varName;
					} else {
						varName;
					}
				} else {
					result;
				}
			}

			final meta = compileMetadata(field.meta, MetadataTarget.ClassField) ?? "";

			if(f.kind == MethDynamic) {
				final e = field.expr();
				final callable = e == null ? "func():\n\tpass" : compileClassVarExpr(e);
				if(f.isStatic) {
					staticVars.push({
						name: name,
						expr: callable
					});
				} else {
					final decl = meta + "var " + name + " = " + callable;
					variables.push(decl);
				}
			} else {
				final args = tfunc?.args ?? [];
				final wrapperSelfName = !isWrapper ? "" : (classType.meta.extractStringFromFirstMeta(Meta.Wrapper) ?? "_self");

				final funcDeclaration = new StringBuf();
				funcDeclaration.add(meta);
				funcDeclaration.add(f.isStatic ? "static " : "");
				funcDeclaration.add("func ");
				funcDeclaration.add(name);
				funcDeclaration.add("(");
				if(isWrapper) {
					funcDeclaration.add(wrapperSelfName);
					if(args.length > 0) {
						funcDeclaration.add(",");
					}
				}
				funcDeclaration.add(args.map(a -> compileFunctionArgument(a, field.pos)).join(", "));
				funcDeclaration.add(")");

				#if !gdscript_untyped
				final returnType = TComp.compileType(f.ret, field.pos);
				if(returnType != null) {
					funcDeclaration.addMulti(" -> ", returnType);
				}
				#end

				funcDeclaration.add(":\n");

				var gdScriptVal = if(f.expr != null) {
					if(isWrapper) {
						selfStack.push(wrapperSelfName);
					}

					// Compile function
					final result = compileClassFuncExpr(f.expr).tab();

					if(isWrapper) {
						selfStack.pop();
					}

					// Use "pass" if function empty
					if(StringTools.trim(result).length == 0) {
						"\tpass";
					} else {
						result;
					}
				} else {
					"\tpass";
				}

				funcDeclaration.add(gdScriptVal);
				
				functions.push(funcDeclaration.toString());
			}
		}

		// static vars
		if(staticVars.length > 0) {
			var declaration = "var _" + className + ": Dictionary = {\n";

			final fields = [];
			for(v in staticVars) {
				fields.push("\t\"" + v.name + "\": " + (v.expr != null ? v.expr : "null"));
			}

			declaration += fields.join(",\n") + "\n";
			declaration += "}\n\n";

			appendToExtraFile("HxStaticVars.gd", declaration);
		}

		// if there are no instance variables or functions,
		// we don't need to generate a class
		if(variables.length <= 0 && functions.length <= 0) {
			return null;
		}

		// TODO - Try this again after Godot beta??
		// Possible bug with GDScript 2.0 beta at the moment, but static
		// functions don't work unless there's a constructor defined.
		// So a blank GDScript constructor is created if one does not exist.
		if(classType.constructor == null) {
			functions.insert(0, "func _init():\n\tpass");
		}

		// Check if extends from Node or Resource
		if(!classType.hasMeta(Meta.DontAddToPlugin)) {
			if(extendsFromNode(classType)) {
				pluginNodeClasses.push(classType);
			}
			if(extendsFromResource(classType)) {
				pluginResourceClasses.push(classType);
			}
		}

		// Put everything together
		final gdscriptContent = {
			var result = new StringBuf();

			result.add(header);

			if(variables.length > 0) {
				result.add(variables.join("\n\n") + "\n\n");
			}

			if(functions.length > 0) {
				result.add(functions.join("\n\n") + "\n\n");
			}

			StringTools.trim(result.toString()) + "\n\n";
		}

		// @:outputFile(path: String)
		var path = if(classType.hasMeta(Meta.OutputFile)) {
			final outputFilePath = classType.meta.extractStringFromFirstMeta(Meta.OutputFile);
			if(outputFilePath == null) {
				final msg = "@:outputFile requires a String path for the first argument.";
				Context.error(msg, classType.meta.getFirstPosition(Meta.OutputFile) ?? classType.pos);
			}
			outputFilePath;
		} else {
			null;
		}

		// Default name
		if(path == null) {
			path = classType.globalName() + ".gd";
		}

		// Generate file
		setExtraFile(path, gdscriptContent);

		return null;
	}

	function compileFunctionArgument(arg: { v: TVar, value: Null<TypedExpr> }, pos: Position) {
		final result = new StringBuf();
		result.add(compileVarName(arg.v.name));
		
		#if !gdscript_untyped
		final type = TComp.compileType(arg.v.t, pos);
		if(type != null) {
			result.addMulti(": ", type);
		}
		#end

		if(arg.value != null) {
			final valueCode = compileExpression(arg.value);
			if(valueCode != null) {
				result.addMulti(" = ", valueCode);
			}
		}

		return result.toString();
	}

	function getNativeMetaString(metaAccess: Null<MetaAccess>) {
		var result = "";
		final nativeMeta = metaAccess.extractNativeMeta();
		if(nativeMeta != null) {
			for(m in nativeMeta) {
				result += "@" + m + "\n";
			}
		}
		return result;
	}

	public function compileEnumImpl(enumType: EnumType, options:Array<EnumOptionData>): Null<String> {
		return null;
	}
  
	public function compileExpressionImpl(expr: TypedExpr, isTopLevel: Bool): Null<String> {
		var result = new StringBuf();
		switch(expr.expr) {
			case TConst(constant): {
				result.add(constantToGDScript(constant));
			}
			case TLocal(v): {
				result.add(compileVarName(v.name, expr));
				if(v.meta.maybeHas(":arrayWrap")) {
					result.add("[0]");	
				}
			}
			case TIdent(s): {
				result.add(compileVarName(s, expr));
			}
			case TArray(e1, e2): {
				result.addMulti(compileExpressionOrError(e1), "[", compileExpressionOrError(e2), "]");
			}
			case TBinop(op, e1, e2): {
				result.add(binopToGDScript(op, e1, e2));
			}
			case TField(e, fa): {
				result.add(fieldAccessToGDScript(e, fa));
			}
			case TTypeExpr(m): {
				result.add(TComp.compileModuleType(m));
			}
			case TParenthesis(e): {
				final gdScript = compileExpressionOrError(e);
				final expr = if(!EverythingIsExprSanitizer.isBlocklikeExpr(e)) {
					"(" + gdScript + ")";
				} else {
					gdScript;
				}
				result.add(expr);
			}
			case TObjectDecl(fields): {
				result.add("{\n");
				for(i in 0...fields.length) {
					final field = fields[i];
					result.addMulti("\t\"", field.name, "\": ");
					result.add(compileExpression(field.expr));
					if(i < fields.length - 1) {
						result.add(",");
					}
					result.add("\n"); 
				}
				result.add("}");
			}
			case TArrayDecl(el): {
				result.add("[");
				result.add(el.map(e -> compileExpression(e)).join(", "));
				result.add("]");
			}
			case TCall(e, el): {
				final nfc = this.compileNativeFunctionCodeMeta(e, el);
				if(nfc != null) {
					result.add(nfc);
				} else {
					final code = switch(e.expr) {
						case TField(_, fa): {
							switch(fa) {
								// enum field access
								case FEnum(_, _): {
									final enumCall = compileEnumFieldCall(e, el);
									if(enumCall != null) enumCall;
									else null;
								}
								// @:constructor static function
								case FStatic(classTypeRef, _.get() => cf) if(cf.meta.maybeHas(":constructor")): {
									newToGDScript(classTypeRef, expr, el);
								}
								// Replace pad nulls with default values
								case FInstance(clsRef, _, cfRef) | FStatic(clsRef, cfRef): {
									final funcData = cfRef.get().findFuncData(clsRef.get());
									if(funcData != null) {
										el = funcData.replacePadNullsWithDefaults(el, ":noNullPad", generateInjectionExpression);
									}
									null;
								}
								case _: null;
							}
						}
						case _: null;
					}

					if(code != null) {
						result.add(code);
					} else {
						final callOp = if(isCallableVar(e)) {
							".call(";
						} else {
							"(";
						}
						result.add(compileExpression(e));
						result.add(callOp);
						result.add(el.map(e -> compileExpressionOrError(e)).join(", "));
						result.add(")");
					}
				}
			}
			case TNew(classTypeRef, _, el): {
				result.add(newToGDScript(classTypeRef, expr, el));
			}
			case TUnop(op, postFix, e): {
				result.add(unopToGDScript(op, e, postFix));
			}
			case TFunction(tfunc): {
				result.add("func(");
				result.add(tfunc.args.map(a -> compileFunctionArgument(a, expr.pos)).join(", "));
				result.add(")");

				// TODO: Return type.

				result.add(":\n");
				result.add(toIndentedScope(tfunc.expr));
			}
			case TVar(tvar, maybeExpr): {
				result.add("var ");
				result.add(compileVarName(tvar.name, expr));
				if(maybeExpr != null) {
					final e = compileExpressionOrError(maybeExpr);
					if(tvar.meta.maybeHas(":arrayWrap")) {
						result.addMulti(" = [", e, "]");	
					} else {
						#if !gdscript_untyped
						final compiledType = TComp.compileType(tvar.t, expr.pos);
						if(compiledType != null) {
							result.addMulti(": ", compiledType);
						}
						#end

						result.addMulti(" = ", e);
					}
				}
			}
			case TBlock(el): {
				result.add("if true:\n");

				if(el.length > 0) {
					result.add(
						el
						.map(e -> compileExpression(e))
						.filter(e -> e != null)
						.map(e -> e.trustMe().tab())
						.join("\n")
					);
				} else {
					result.add("\tpass");
				}
			}
			case TFor(tvar, iterExpr, blockExpr): {
				result.addMulti(
					"for ", tvar.name, " in ", compileExpressionOrError(iterExpr), ":\n"
				);
				result.add(toIndentedScope(blockExpr));
			}
			case TIf(econd, ifExpr, elseExpr): {
				result.addMulti("if ", compileExpressionOrError(econd), ":\n");
				result.add(toIndentedScope(ifExpr));
				if(elseExpr != null) {
					result.add("\n");
					result.add("else:\n");
					result.add(toIndentedScope(elseExpr));
				}
			}
			case TWhile(econd, blockExpr, normalWhile): {
				final gdCond = compileExpressionOrError(econd);
				if(normalWhile) {
					result.addMulti("while ", gdCond, ":\n");
					result.add(toIndentedScope(blockExpr));
				} else {
					result.add("while true:\n");
					result.add(toIndentedScope(blockExpr));
					result.addMulti("\tif ", gdCond, ":\n");
					result.add("\t\tbreak");
				}
			}
			case TSwitch(e, cases, edef): {
				result.addMulti("match ", compileExpressionOrError(e), ":");
				for(c in cases) {
					result.add("\n\t");
					result.add(c.values.map(v -> compileExpression(v)).join(", "));
					result.add(":\n");
					result.add(toIndentedScope(c.expr).toString().tab());
				}
				if(edef != null) {
					result.add("\n\t_:\n");
					result.add(toIndentedScope(edef).toString().tab());
				}
			}
			case TTry(e, catches): {
				result.add(compileExpressionOrError(e));
				final msg = "GDScript does not support try-catch. The expressions contained in the try block will be compiled, and the catches will be ignored.";
				Context.warning(msg, expr.pos);
			}
			case TReturn(maybeExpr): {
				result.add("return");
				if(maybeExpr != null) {
					result.add(" ");
					result.add(compileExpression(maybeExpr));
				}
			}
			case TBreak: {
				result.add("break");
			}
			case TContinue: {
				result.add("continue");
			}
			case TThrow(expr): {
				result.addMulti("assert(false, ", compileExpressionOrError(expr), ")");
			}
			case TCast(expr, maybeModuleType): {
				final hasModuleType = maybeModuleType != null;
				if(hasModuleType) {
					result.add("(");
				}
				result.add(compileExpressionOrError(expr));
				if(hasModuleType) {
					result.addMulti(" as ", TComp.compileModuleType(maybeModuleType.trustMe()), ")");
				}
			}
			case TMeta(metadataEntry, expr): {
				result.add(compileExpressionOrError(expr));
			}
			case TEnumParameter(expr, enumField, index): {
				result.add(compileExpressionOrError(expr));
				switch(enumField.type) {
					case TFun(args, _): {
						if(index < args.length) {
							result.addMulti(".", args[index].name);
						}
					}
					case _:
				}
			}
			case TEnumIndex(expr): {
				result.addMulti(compileExpressionOrError(expr), "._index");
			}
		}
		return result.toString();
	}

	function toIndentedScope(e: TypedExpr): StringBuf {
		final result = new StringBuf();
		switch(e.expr) {
			case TBlock(el): {
				if(el.length > 0) {
					for(i in 0...el.length) {
						final code = compileExpression(el[i]);
						if(code != null) {
							result.add(code.tab());
							if(i < el.length - 1) {
								result.add("\n");
							}
						}
					}
				} else {
					result.add("\tpass");
				}
			}
			case _: {
				final gdscript = compileExpression(e) ?? "pass";
				result.add(gdscript.tab());
			}
		}
		return result;
	}

	function constantToGDScript(constant: TConstant): String {
		switch(constant) {
			case TInt(i): return Std.string(i);
			case TFloat(s): return s;
			case TString(s): return "\"" + StringTools.replace(StringTools.replace(s, "\\", "\\\\"), "\"", "\\\"") + "\"";
			case TBool(b): return b ? "true" : "false";
			case TNull: return "null";
			case TThis: {
				if(selfStack.length > 0) {
					return selfStack[selfStack.length - 1];
				}
				return "self";
			}
			case TSuper: return "super";
			case _: {}
		}
		return "";
	}

	function binopToGDScript(op: Binop, e1: TypedExpr, e2: TypedExpr): String {
		var gdExpr1 = compileExpression(e1);
		var gdExpr2 = compileExpression(e2);
		final operatorStr = OperatorHelper.binopToString(op);

		// Wrap primitives with str(...) when added with String
		if(op.isAddition()) {
			if(checkForPrimitiveStringAddition(e1, e2)) gdExpr2 = "str(" + gdExpr2 + ")";
			if(checkForPrimitiveStringAddition(e2, e1)) gdExpr1 = "str(" + gdExpr1 + ")";
		}

		return gdExpr1 + " " + operatorStr + " " + gdExpr2;
	}

	inline function checkForPrimitiveStringAddition(strExpr: TypedExpr, primExpr: TypedExpr) {
		return strExpr.t.isString() && primExpr.t.isPrimitive();
	}

	function newToGDScript(classTypeRef: Ref<ClassType>, originalExpr: TypedExpr, el: Array<TypedExpr>): String {
		final nfc = this.compileNativeFunctionCodeMeta(originalExpr, el);
		return if(nfc != null) {
			nfc;
		} else {
			final meta = originalExpr.getDeclarationMeta()?.meta;
			final native = meta == null ? "" : ({ name: "", meta: meta }.getNameOrNative());
			final args = el.map(e -> compileExpression(e)).join(", ");
			if(native.length > 0) {
				native + "(" + args + ")";
			} else {
				final cls = classTypeRef.get();
				final className = TComp.compileClassName(cls);
				final meta = cls.meta.maybeExtract(":bindings_api_type");

				// Check for @:bindings_api_type("builtin_classes") metadata
				final builtin_class = meta.filter(m -> switch(m.params) {
					case [macro "builtin_classes"]: true;
					case _: false;
				}).length > 0;

				if(builtin_class) {
					className + "(" + args + ")";
				} else {
					className + ".new(" + args + ")";
				}
			}
		}
	}

	function unopToGDScript(op: Unop, e: TypedExpr, isPostfix: Bool): String {
		final gdExpr = compileExpressionOrError(e);

		// OpIncrement and OpDecrement not supported in GDScript
		switch(op) {
			case OpIncrement: {
				return gdExpr + " += 1";
			}
			case OpDecrement: {
				return gdExpr + " -= 1";
			}
			case _:
		}

		final operatorStr = OperatorHelper.unopToString(op);
		return isPostfix ? (gdExpr + operatorStr) : (operatorStr + gdExpr);
	}

	function fieldAccessToGDScript(e: TypedExpr, fa: FieldAccess): String {
		final nameMeta: NameAndMeta = switch(fa) {
			case FInstance(_, _, classFieldRef): classFieldRef.get();
			case FStatic(_, classFieldRef): classFieldRef.get();
			case FAnon(classFieldRef): classFieldRef.get();
			case FClosure(_, classFieldRef): classFieldRef.get();
			case FEnum(_, enumField): enumField;
			case FDynamic(s): { name: s, meta: null };
		}

		return if(nameMeta.hasMeta(":native")) {
			nameMeta.getNameOrNative();
		} else {
			final name = compileVarName(nameMeta.getNameOrNativeName());

			var bypassSelf = false;

			switch(fa) {
				// Check if this is a self.field with BypassWrapper
				case FInstance(_, _, clsFieldRef): {
					final isSelfAccess = switch(e.expr) {
						case TConst(TThis): true;
						case _: false;
					}
					if(isSelfAccess) {
						bypassSelf = clsFieldRef.get().hasMeta(Meta.BypassWrapper);
					}
				}

				// Check if this is a static variable, and if so use singleton.
				case FStatic(clsRef, cfRef): {
					final cls = clsRef.get();
					final cf = cfRef.get();
					final className = TComp.compileClassName(cls);
					switch(cf.kind) {
						case FVar(_, _) if(!cf.isExtern && !cls.isReflaxeExtern()): {
							return "HxStaticVars._" + className + "." + name;
						}
						case FMethod(kind): {
							if(kind == MethDynamic) {
								return "HxStaticVars._" + className + "." + name;
							}
						}
						case _:
					}
				}

				// Check if this is an enum 
				// TODO... is this correct??? I wrote this in 2022 but idk how this works??
				case FEnum(enumRef, enumField): {
					final enumType = enumRef.get();
					if(enumType.isReflaxeExtern()) {
						return enumType.getNameOrNative() + "." + enumField.name;
					}

					return "{ \"_index\": " + enumField.index + " }";
				}
				case _:
			}

			final gdExpr = bypassSelf ? "self" : compileExpression(e);

			// Check if we're accessing an anonymous type.
			// If so, it's a Dictionary in GDScript and .get should be used.
			switch(fa) {
				case FAnon(classFieldRef): {
					return gdExpr + ".get(\"" + classFieldRef.get().name + "\")";
				}
				case _:
			}

			return gdExpr + "." + name;
		}
	}

	

	/**
		In GDScript, a Callable is called differently from a function.
		To help decern whether this is a variable containing a Callable,
		or this is a normal function/method, this function is used.
	**/
	function isCallableVar(e: TypedExpr) {
		return switch(e.expr) {
			case TField(_, fa): {
				switch(fa) {
					case FInstance(_, _, clsFieldRef) |
						FStatic(_, clsFieldRef) |
						FClosure(_, clsFieldRef): {
						final clsField = clsFieldRef.get();
						switch(clsField.kind) {
							case FMethod(methKind): {
								methKind == MethDynamic;
							}
							case _: true;
						}
					}
					case _: true;
				}
			}
			case TConst(c): c != TSuper;
			case TParenthesis(e2) | TMeta(_, e2): isCallableVar(e2);
			case _: true;
		}
	}

	/**
		This is called for called expressions.
		If the typed expression is an enum field, transpile as a
		Dictionary with the enum data.
	**/
	function compileEnumFieldCall(e: TypedExpr, el: Array<TypedExpr>): Null<String> {
		final ef = switch(e.expr) {
			case TField(_, fa): {
				switch(fa) {
					case FEnum(enumRef, ef): {
						if(enumRef.get().isReflaxeExtern()) {
							return ef.name;
						}
						ef;
					}
					case _: null;
				}
			}
			case _: null;
		}

		return if(ef != null) {
			var result = new StringBuf();
			switch(ef.type) {
				case TFun(args, _): {
					result.addMulti("{ \"_index\": ", Std.string(ef.index), ", ");
					final fields = [];
					for(i in 0...el.length) {
						if(args[i] != null) {
							result.addMulti("\"", args[i].name, "\": ", compileExpressionOrError(el[i]));
							if(i < el.length - 1) {
								result.add(", ");
							}
						}
					}
					result.add(" }");
				}
				case _:
			}
			result.toString();
		} else {
			null;
		}
	}
}

#end
