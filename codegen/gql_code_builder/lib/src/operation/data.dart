import "package:built_collection/built_collection.dart";
import "package:code_builder/code_builder.dart";
import "package:collection/collection.dart";
import "package:gql/ast.dart";
import "package:gql_code_builder/data.dart";
import "package:gql_code_builder/src/config/when_extension_config.dart";

import "../../source.dart";
import "../built_class.dart";
import "../common.dart";
import "../inline_fragment_classes.dart";

List<Spec> buildOperationDataClasses(
  OperationDefinitionNode op,
  SourceNode docSource,
  SourceNode schemaSource,
  Map<String, Reference> typeOverrides,
  InlineFragmentSpreadWhenExtensionConfig whenExtensionConfig,
  FragmentRefMap fragmentRefMap,
) {
  if (op.name == null) {
    throw Exception("Operations must be named");
  }

  final fragmentMap = _fragmentMap(docSource);
  return buildSelectionSetDataClasses(
    name: "${op.name!.value}Data",
    selections: mergeSelections(op.selectionSet.selections, fragmentMap, true),
    schemaSource: schemaSource,
    type: _operationType(
      schemaSource.document,
      op,
    ),
    typeOverrides: typeOverrides,
    fragmentMap: fragmentMap,
    superclassSelections: {},
    whenExtensionConfig: whenExtensionConfig,
    fragmentRefMap: fragmentRefMap,
  );
}

List<Spec> buildFragmentDataClasses(
  FragmentDefinitionNode frag,
  SourceNode docSource,
  SourceNode schemaSource,
  Map<String, Reference> typeOverrides,
  InlineFragmentSpreadWhenExtensionConfig whenExtensionConfig,
  FragmentRefMap fragmentRefMap,
  Map<String, Set<String>> possibleTypesMap,
) {
  final fragmentMap = _fragmentMap(docSource);
  final selections =
      mergeSelections(frag.selectionSet.selections, fragmentMap, true);

  final set = BuiltSet.of(selections.withoutFragmentSpreads);

  final fragmentType = frag.typeCondition.on.name.value;

  if (fragmentRefMap.containsKey((fragmentType, set))) {
    print(
        "***** warning: duplicated fragment found: ${frag.name.value} on ${frag.typeCondition.on.name.value} in ${docSource.url}, previous defintion with same data ${fragmentRefMap[(
      fragmentType,
      set
    )]}");

    print("on type: $fragmentType");
  }

  fragmentRefMap[(fragmentType, set)] = refer(
    builtClassName("${frag.name.value}Data"),
    (docSource.url ?? "") + "#data",
  );
  //TODO
  /*for (final possibleType in possibleTypesMap[fragmentType] ?? <String>{}) {
    fragmentRefMap[(possibleType, set)] = refer(
      builtClassName("${frag.name.value}Data"),
      (docSource.url ?? "") + "#data",
    );
  }*/

  return [
    // abstract class that will implemented by any class that uses the fragment
    ...buildSelectionSetDataClasses(
      name: frag.name.value,
      selections: selections,
      schemaSource: schemaSource,
      type: frag.typeCondition.on.name.value,
      typeOverrides: typeOverrides,
      fragmentMap: fragmentMap,
      superclassSelections: {},
      built: false,
      whenExtensionConfig: whenExtensionConfig,
      fragmentRefMap: fragmentRefMap,
    ),
    // concrete built_value data class for fragment
    ...buildSelectionSetDataClasses(
      name: "${frag.name.value}Data",
      selections: selections,
      schemaSource: schemaSource,
      type: frag.typeCondition.on.name.value,
      typeOverrides: typeOverrides,
      fragmentMap: fragmentMap,
      superclassSelections: {
        frag.name.value: SourceSelections(
          url: docSource.url,
          selections: selections,
        )
      },
      whenExtensionConfig: whenExtensionConfig,
      fragmentRefMap: fragmentRefMap,
    ),
  ];
}

String _operationType(
  DocumentNode schema,
  OperationDefinitionNode op,
) {
  final schemaDefs = schema.definitions.whereType<SchemaDefinitionNode>();

  if (schemaDefs.isEmpty) return defaultRootTypes[op.type]!;

  return schemaDefs.first.operationTypes
      .firstWhere(
        (opType) => opType.operation == op.type,
      )
      .type
      .name
      .value;
}

Map<String, SourceSelections> _fragmentMap(SourceNode source) => {
      for (final def
          in source.document.definitions.whereType<FragmentDefinitionNode>())
        def.name.value: SourceSelections(
          url: source.url,
          selections: def.selectionSet.selections,
        ),
      for (final import in source.imports) ..._fragmentMap(import)
    };

/// Builds one or more data classes, with properties based on [selections].
///
/// For each selection that is a field with nested selections, a descendent
/// data class will also be created.
///
/// If this class is for a fragment definition or descendent, set [built] == `false`,
/// and it will be built as an abstract class which will be implemented by any
/// class that includes the fragment (or descendent) as a spread in its
/// [selections].
List<Spec> buildSelectionSetDataClasses({
  required String name,
  required List<SelectionNode> selections,
  required SourceNode schemaSource,
  required String type,
  required Map<String, Reference> typeOverrides,
  required Map<String, SourceSelections> fragmentMap,
  required Map<String, SourceSelections> superclassSelections,
  bool built = true,
  required InlineFragmentSpreadWhenExtensionConfig whenExtensionConfig,
  required FragmentRefMap fragmentRefMap,
}) {
  for (final selection in selections.whereType<FragmentSpreadNode>()) {
    if (!fragmentMap.containsKey(selection.name.value)) {
      throw Exception(
          "Couldn't find fragment definition for fragment spread '${selection.name.value}'");
    }
    superclassSelections["${selection.name.value}"] = SourceSelections(
      url: fragmentMap[selection.name.value]!.url,
      selections: mergeSelections(
        fragmentMap[selection.name.value]!.selections,
        fragmentMap,
      ).whereType<FieldNode>().toList(),
    );
  }

  final canonicalSelections = BuiltSet.of(selections.withoutFragmentSpreads);

  final superclassSelectionNodes = superclassSelections.values
      .expand((selections) => selections.selections)
      .toSet();

  final fieldsThatAreSingleFragmentSpreads = <FieldNode>{};

  final fieldGetters = selections.whereType<FieldNode>().map<Method>(
    (node) {
      final nameNode = node.alias ?? node.name;
      final typeDef = getTypeDefinitionNode(
        schemaSource.document,
        type,
      )!;
      final typeNode = _getFieldTypeNode(
        typeDef,
        node.name.value,
      );

      final getterSelections = node.selectionSet;

      Reference? fragmentRef;

      if (getterSelections != null) {
        final mergedGetterSelections = [
          ...mergeSelections(getterSelections.selections, fragmentMap, true),
        ];

        if (node.name.value == "hero") {
          print(
              "mergedGetterSelections: $mergedGetterSelections from ${getterSelections.selections}");
        }

        final withoutFragmentSpreads =
            mergedGetterSelections.withoutFragmentSpreads.toBuiltSet();

        final fieldTypeDefNode = getTypeDefinitionNode(
          schemaSource.document,
          unwrapTypeNode(typeNode).name.value,
        );

        if (fieldTypeDefNode == null) {
          throw Exception(
              "Couldn't find type definition for ${unwrapTypeNode(typeNode).name.value}");
        }

        final hasMatchingFragment = fragmentRefMap[(
          fieldTypeDefNode.name.value,
          withoutFragmentSpreads
        )];

        if (hasMatchingFragment != null) {
          fieldsThatAreSingleFragmentSpreads.add(node);
        } else if (node.name.value == "hero") {
          print(
              "no matching fragment for ${node.name.value} on ${fieldTypeDefNode.name.value} with selections: $withoutFragmentSpreads, original selections: ${node.selectionSet?.selections}");
          print(fragmentRefMap);
        }

        fragmentRef = hasMatchingFragment;
      }

      return buildGetter(
        nameNode: nameNode,
        typeNode: typeNode,
        schemaSource: schemaSource,
        typeOverrides: typeOverrides,
        fragmentRef: fragmentRef,
        typeRefPrefix: node.selectionSet != null ? builtClassName(name) : null,
        built: built,
        isOverride: superclassSelectionNodes.contains(node),
      );
    },
  ).toList();

  final inlineFragments = selections.whereType<InlineFragmentNode>().toList();

  return [
    if (inlineFragments.isNotEmpty)
      ...buildInlineFragmentClasses(
        name: name,
        fieldGetters: fieldGetters,
        selections: selections,
        schemaSource: schemaSource,
        type: type,
        typeOverrides: typeOverrides,
        fragmentMap: fragmentMap,
        superclassSelections: superclassSelections,
        inlineFragments: inlineFragments,
        built: built,
        whenExtensionConfig: whenExtensionConfig,
        fragmentRefMap: fragmentRefMap,
      )
    else if (!built)
      () {
        final clazz = Class(
          (b) => b
            ..abstract = true
            ..name = builtClassName(name)
            ..implements.addAll(
              superclassSelections.keys.map<Reference>(
                (superName) => refer(
                  builtClassName(superName),
                  (superclassSelections[superName]?.url ?? "") + "#data",
                ),
              ),
            )
            ..methods.addAll([
              ...fieldGetters,
              buildToJsonGetter(
                builtClassName(name),
                implemented: false,
                isOverride: superclassSelections.isNotEmpty,
              ),
            ]),
        );
        return clazz;
      }()
    else
      builtClass(
        name: name,
        getters: fieldGetters,
        initializers: {
          if (fieldGetters.any((getter) => getter.name == "G__typename"))
            "G__typename": literalString(type),
        },
        superclassSelections: superclassSelections,
      ),
    // Build classes for each field that includes selections
    ...selections
        .whereType<FieldNode>()
        .where(
          (field) =>
              field.selectionSet != null &&
              !fieldsThatAreSingleFragmentSpreads.contains(field),
        )
        .expand(
          (field) => buildSelectionSetDataClasses(
            name: "${name}_${field.alias?.value ?? field.name.value}",
            selections: field.selectionSet!.selections,
            fragmentMap: fragmentMap,
            schemaSource: schemaSource,
            type: unwrapTypeNode(
              _getFieldTypeNode(
                getTypeDefinitionNode(
                  schemaSource.document,
                  type,
                )!,
                field.name.value,
              ),
            ).name.value,
            typeOverrides: typeOverrides,
            superclassSelections: _fragmentSelectionsForField(
              superclassSelections,
              field,
            ),
            built: inlineFragments.isNotEmpty ? false : built,
            whenExtensionConfig: whenExtensionConfig,
            fragmentRefMap: fragmentRefMap,
          ),
        ),
  ];
}

/// Deeply merges field nodes
List<SelectionNode> mergeSelections(List<SelectionNode> selections,
        Map<String, SourceSelections> fragmentMap,
        [bool keepInlineFragments = true]) =>
    _expandFragmentSpreads(selections, fragmentMap, keepInlineFragments)
        .fold<Map<String, SelectionNode>>(
          {},
          (selectionMap, selection) {
            if (selection is FieldNode) {
              final key = selection.alias?.value ?? selection.name.value;
              if (selection.selectionSet == null) {
                selectionMap[key] = selection;
              } else {
                final existingNode = selectionMap[key];
                final existingSelections = existingNode is FieldNode &&
                        existingNode.selectionSet != null
                    ? existingNode.selectionSet!.selections
                    : <SelectionNode>[];
                selectionMap[key] = FieldNode(
                  name: selection.name,
                  alias: selection.alias,
                  selectionSet: SelectionSetNode(
                    selections: mergeSelections(
                      [
                        ...existingSelections,
                        ...selection.selectionSet!.selections
                      ],
                      fragmentMap,
                      keepInlineFragments,
                    ),
                  ),
                );
              }
            } else {
              if (selectionMap[selection.hashCode.toString()] != null) {
                print("duplicate selection or hash coll: $selection");
              }
              selectionMap[selection.hashCode.toString()] = selection;
            }
            return selectionMap;
          },
        )
        .values
        .toList();

List<SelectionNode> _expandFragmentSpreads(
  List<SelectionNode> selections,
  Map<String, SourceSelections> fragmentMap, [
  bool retainFragmentSpreads = true,
  bool keepInlineFragments = true,
]) =>
    selections.expand(
      (selection) {
        if (selection is FragmentSpreadNode) {
          if (!fragmentMap.containsKey(selection.name.value)) {
            throw Exception(
              "Couldn't find fragment definition for fragment spread '${selection.name.value}'",
            );
          }

          final fragmentSelections =
              fragmentMap[selection.name.value]!.selections;

          return [
            if (retainFragmentSpreads) selection,
            ..._expandFragmentSpreads(
              [
                ...fragmentSelections.whereType<FieldNode>(),
                ...fragmentSelections.whereType<FragmentSpreadNode>(),
                if (keepInlineFragments)
                  ...fragmentSelections.whereType<InlineFragmentNode>(),
              ],
              fragmentMap,
              keepInlineFragments,
            ),
          ];
        }
        return [selection];
      },
    ).toList();

Map<String, SourceSelections> _fragmentSelectionsForField(
  Map<String, SourceSelections> fragmentMap,
  FieldNode field,
) =>
    Map.fromEntries(
      fragmentMap.entries.expand(
        (entry) => entry.value.selections.whereType<FieldNode>().where(
          (selection) {
            if (selection.selectionSet == null) return false;

            final selectionKey = selection.alias?.value ?? selection.name.value;
            final fieldKey = field.alias?.value ?? field.name.value;

            return selectionKey == fieldKey;
          },
        ).map(
          (selection) => MapEntry(
            "${entry.key}_${field.alias?.value ?? field.name.value}",
            SourceSelections(
              url: entry.value.url,
              selections: selection.selectionSet!.selections
                  .whereType<FieldNode>()
                  .toList(),
            ),
          ),
        ),
      ),
    );

TypeNode _getFieldTypeNode(
  TypeDefinitionNode node,
  String field,
) {
  if (node is UnionTypeDefinitionNode && field == "__typename") {
    return NamedTypeNode(
      isNonNull: true,
      name: NameNode(value: "String"),
    );
  }

  List<FieldDefinitionNode> fields;
  if (node is ObjectTypeDefinitionNode) {
    fields = node.fields;
  } else if (node is InterfaceTypeDefinitionNode) {
    fields = node.fields;
  } else {
    throw Exception(
        "${node.name.value} is not an ObjectTypeDefinitionNode or InterfaceTypeDefinitionNode");
  }
  return fields
      .firstWhere(
        (fieldNode) => fieldNode.name.value == field,
      )
      .type;
}

extension IsSingleFragmentSpread on SelectionSetNode {
  Iterable<FragmentSpreadNode> get fragmentSpreads =>
      selections.whereType<FragmentSpreadNode>();

  Iterable<InlineFragmentNode> get inlineFragments =>
      selections.whereType<InlineFragmentNode>();

  Iterable<FieldNode> get fields => selections.whereType<FieldNode>();
}

extension WithoutFragmentSpreads on Iterable<SelectionNode> {
  Iterable<SelectionNode> get withoutFragmentSpreads =>
      where((selection) => selection is! FragmentSpreadNode).map((e) {
        if (e is FieldNode) {
          if (e.selectionSet == null) return e;
          return FieldNode(
            name: e.name,
            alias: e.alias,
            arguments: e.arguments,
            directives: e.directives,
            selectionSet: SelectionSetNode(
              selections:
                  e.selectionSet!.selections.withoutFragmentSpreads.toList(),
            ),
          );
        }
        if (e is InlineFragmentNode) {
          return InlineFragmentNode(
            typeCondition: e.typeCondition,
            directives: e.directives,
            selectionSet: SelectionSetNode(
              selections:
                  e.selectionSet.selections.withoutFragmentSpreads.toList(),
            ),
          );
        }
        return e;
      });
}
