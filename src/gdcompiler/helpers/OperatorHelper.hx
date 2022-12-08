package gdcompiler.helpers;

#if (macro || gdscript_runtime)

import haxe.macro.Expr;

class OperatorHelper {
	public static function binopToString(op: Binop): String {
		return switch(op) {
			case OpAdd: "+";
			case OpMult: "*";
			case OpDiv: "/";
			case OpSub: "-";
			case OpAssign: "=";
			case OpEq: "==";
			case OpNotEq: "!=";
			case OpGt: ">";
			case OpGte: ">=";
			case OpLt: "<";
			case OpLte: "<=";
			case OpAnd: "&";
			case OpOr: "|";
			case OpXor: "^";
			case OpBoolAnd: "&&";
			case OpBoolOr: "||";
			case OpShl: "<<";
			case OpShr: ">>";
			case OpUShr: ">>>";
			case OpMod: "%";
			case OpAssignOp(assignOp): binopToString(assignOp) + "=";
			case OpInterval: "...";
			case OpArrow: "=>";
			case OpIn: "in";
		}
	}

	public static function unopToString(op: Unop): String {
		return switch(op) {
			case OpIncrement: "++";
			case OpDecrement: "--";
			case OpNot: "!";
			case OpNeg: "-";
			case OpNegBits: "~";
			case OpSpread: "...";
		}
	}
}

#end
