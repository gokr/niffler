(struct_specifier name: (type_identifier) @name.definition.class body:(_)) @definition.class

(declaration type: (union_specifier name: (type_identifier) @name.definition.class)) @definition.class

(function_declarator declarator: (identifier) @name.definition.function) @definition.function

(type_definition declarator: (type_identifier) @name.definition.type) @definition.type

(enum_specifier name: (type_identifier) @name.definition.type) @definition.type

;; references — aider's c query is definitions-only (it backfills refs with
;; pygments at runtime); the graph needs refs, so capture calls here
(call_expression function: (identifier) @name.reference.call) @reference.call
