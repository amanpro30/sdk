// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js_emitter.metadata_collector;

import 'package:js_ast/src/precedence.dart' as js_precedence;

import '../common.dart';
import '../constants/values.dart';
import '../deferred_load.dart' show OutputUnit;
import '../elements/elements.dart'
    show
        ClassElement,
        Element,
        FieldElement,
        FunctionSignature,
        LibraryElement,
        MemberElement,
        MethodElement,
        MetadataAnnotation,
        ParameterElement;
import '../elements/entities.dart' show FunctionEntity;

import '../elements/entities.dart';
import '../elements/resolution_types.dart' show ResolutionTypedefType;
import '../elements/types.dart';
import '../js/js.dart' as jsAst;
import '../js/js.dart' show js;
import '../js_backend/mirrors_data.dart';
import '../js_backend/runtime_types.dart' show RuntimeTypesEncoder;
import '../js_backend/type_variable_handler.dart'
    show TypeVariableCodegenAnalysis;
import '../options.dart';
import '../universe/world_builder.dart' show CodegenWorldBuilder;

import 'code_emitter_task.dart' show Emitter;

/// Represents an entry's position in one of the global metadata arrays.
///
/// [_rc] is used to count the number of references of the token in the
/// ast for a program.
/// [value] is the actual position, once they have been finalized.
abstract class _MetadataEntry extends jsAst.DeferredNumber
    implements Comparable, jsAst.ReferenceCountedAstNode {
  jsAst.Expression get entry;
  int get value;
  int get _rc;

  // Mark this entry as seen. On the first time this is seen, the visitor
  // will be applied to the [entry] to also mark potential [_MetadataEntry]
  // instances in the [entry] as seen.
  markSeen(jsAst.TokenCounter visitor);
}

class _BoundMetadataEntry extends _MetadataEntry {
  int _value = -1;
  int _rc = 0;
  final jsAst.Expression entry;

  _BoundMetadataEntry(this.entry);

  bool get isFinalized => _value != -1;

  finalize(int value) {
    assert(!isFinalized);
    _value = value;
  }

  int get value {
    assert(isFinalized);
    return _value;
  }

  bool get isUsed => _rc > 0;

  markSeen(jsAst.BaseVisitor visitor) {
    _rc++;
    if (_rc == 1) entry.accept(visitor);
  }

  int compareTo(covariant _MetadataEntry other) => other._rc - this._rc;
}

abstract class Placeholder implements jsAst.DeferredNumber {
  bind(_MetadataEntry entry);
}

class _ForwardingMetadataEntry extends _MetadataEntry implements Placeholder {
  _MetadataEntry _forwardTo;
  var debug;

  bool get isBound => _forwardTo != null;

  _ForwardingMetadataEntry([this.debug]);

  _MetadataEntry get forwardTo {
    assert(isBound, 'unbound $this $debug');
    return _forwardTo;
  }

  jsAst.Expression get entry {
    return forwardTo.entry;
  }

  int get value {
    return forwardTo.value;
  }

  int get _rc => forwardTo._rc;

  markSeen(jsAst.BaseVisitor visitor) => forwardTo.markSeen(visitor);

  int compareTo(other) => forwardTo.compareTo(other);

  bind(_MetadataEntry entry) {
    assert(!isBound);
    _forwardTo = entry;
  }
}

class _MetadataList extends jsAst.DeferredExpression {
  jsAst.Expression _value;

  void setExpression(jsAst.Expression value) {
    assert(_value == null);
    assert(value.precedenceLevel == this.precedenceLevel);
    _value = value;
  }

  jsAst.Expression get value {
    assert(_value != null);
    return _value;
  }

  int get precedenceLevel => js_precedence.PRIMARY;
}

class MetadataCollector implements jsAst.TokenFinalizer {
  final CompilerOptions _options;
  final DiagnosticReporter reporter;
  final Emitter _emitter;
  final TypeVariableCodegenAnalysis _typeVariableCodegenAnalysis;
  final MirrorsData _mirrorsData;
  final RuntimeTypesEncoder _rtiEncoder;
  final CodegenWorldBuilder _codegenWorldBuilder;

  /// A map with a token per output unit for a list of expressions that
  /// represent metadata, parameter names and type variable types.
  Map<OutputUnit, _MetadataList> _metadataTokens =
      new Map<OutputUnit, _MetadataList>();

  jsAst.Expression getMetadataForOutputUnit(OutputUnit outputUnit) {
    return _metadataTokens.putIfAbsent(outputUnit, () => new _MetadataList());
  }

  /// A map used to canonicalize the entries of metadata.
  Map<OutputUnit, Map<String, _BoundMetadataEntry>> _metadataMap =
      <OutputUnit, Map<String, _BoundMetadataEntry>>{};

  /// A map with a token for a lists of JS expressions, one token for each
  /// output unit. Once finalized, the entries represent types including
  /// function types and typedefs.
  Map<OutputUnit, _MetadataList> _typesTokens =
      new Map<OutputUnit, _MetadataList>();

  jsAst.Expression getTypesForOutputUnit(OutputUnit outputUnit) {
    return _typesTokens.putIfAbsent(outputUnit, () => new _MetadataList());
  }

  /// A map used to canonicalize the entries of types.
  Map<OutputUnit, Map<DartType, _BoundMetadataEntry>> _typesMap =
      <OutputUnit, Map<DartType, _BoundMetadataEntry>>{};

  MetadataCollector(
      this._options,
      this.reporter,
      this._emitter,
      this._typeVariableCodegenAnalysis,
      this._mirrorsData,
      this._rtiEncoder,
      this._codegenWorldBuilder);

  jsAst.Fun buildLibraryMetadataFunction(LibraryEntity element) {
    if (!_mirrorsData.mustRetainMetadata ||
        !_mirrorsData.isLibraryReferencedFromMirrorSystem(element)) {
      return null;
    }
    return _buildMetadataFunction(element as LibraryElement);
  }

  jsAst.Fun buildClassMetadataFunction(ClassEntity cls) {
    if (!_mirrorsData.mustRetainMetadata ||
        !_mirrorsData.isClassReferencedFromMirrorSystem(cls)) {
      return null;
    }
    // TODO(redemption): Handle class entities.
    ClassElement element = cls;
    return _buildMetadataFunction(element);
  }

  bool _mustEmitMetadataForMember(MemberEntity member) {
    if (!_mirrorsData.mustRetainMetadata) {
      return false;
    }
    // TODO(redemption): Handle member entities.
    MemberElement element = member;
    return _mirrorsData.isMemberReferencedFromMirrorSystem(element);
  }

  jsAst.Fun buildFieldMetadataFunction(FieldEntity field) {
    if (!_mustEmitMetadataForMember(field)) return null;
    // TODO(redemption): Handle field entities.
    FieldElement element = field;
    return _buildMetadataFunction(element);
  }

  /// The metadata function returns the metadata associated with
  /// [element] in generated code.  The metadata needs to be wrapped
  /// in a function as it refers to constants that may not have been
  /// constructed yet.  For example, a class is allowed to be
  /// annotated with itself.  The metadata function is used by
  /// mirrors_patch to implement DeclarationMirror.metadata.
  jsAst.Fun _buildMetadataFunction(Element element) {
    return reporter.withCurrentElement(element, () {
      return null;
    });
  }

  List<jsAst.DeferredNumber> reifyDefaultArguments(
      FunctionEntity function, OutputUnit outputUnit) {
    // TODO(sra): These are stored on the InstanceMethod or StaticDartMethod.
    List<jsAst.DeferredNumber> defaultValues = <jsAst.DeferredNumber>[];
    _codegenWorldBuilder.forEachParameter(function,
        (_, String name, ConstantValue constant) {
      if (constant == null) return;
      jsAst.Expression expression = _emitter.constantReference(constant);
      defaultValues.add(_addGlobalMetadata(expression, outputUnit));
    });
    return defaultValues;
  }

  Map<ParameterElement, ParameterElement>
      mapRedirectingFactoryConstructorOptionalParameters(
          FunctionSignature source, FunctionSignature target) {
    var map = <ParameterElement, ParameterElement>{};

    if (source.optionalParametersAreNamed !=
        target.optionalParametersAreNamed) {
      // No legal optional arguments due to mismatch between named vs positional
      // optional arguments.
      return map;
    }

    if (source.optionalParametersAreNamed) {
      for (ParameterElement element in source.optionalParameters) {
        for (ParameterElement redirectedElement in target.optionalParameters) {
          if (element.name == redirectedElement.name) {
            map[element] = redirectedElement;
            break;
          }
        }
      }
    } else {
      int i = source.requiredParameterCount;
      for (ParameterElement element in source.orderedOptionalParameters) {
        if (i >= target.requiredParameterCount && i < target.parameterCount) {
          map[element] = target
              .orderedOptionalParameters[i - target.requiredParameterCount];
        }
        ++i;
      }
    }
    return map;
  }

  jsAst.Expression reifyMetadata(
      MetadataAnnotation annotation, OutputUnit outputUnit) {
    return null;
  }

  jsAst.Expression reifyType(DartType type, OutputUnit outputUnit,
      {ignoreTypeVariables: false}) {
    return addTypeInOutputUnit(type, outputUnit,
        ignoreTypeVariables: ignoreTypeVariables);
  }

  jsAst.Expression reifyName(String name, OutputUnit outputUnit) {
    return _addGlobalMetadata(js.string(name), outputUnit);
  }

  jsAst.Expression reifyExpression(
      jsAst.Expression expression, OutputUnit outputUnit) {
    return _addGlobalMetadata(expression, outputUnit);
  }

  Placeholder getMetadataPlaceholder([debug]) {
    return new _ForwardingMetadataEntry(debug);
  }

  _MetadataEntry _addGlobalMetadata(jsAst.Node node, OutputUnit outputUnit) {
    String nameToKey(jsAst.Name name) => "${name.key}";
    String printed = jsAst.prettyPrint(node,
        enableMinification: _options.enableMinification,
        renamerForNames: nameToKey);
    _metadataMap[outputUnit] ??= new Map<String, _BoundMetadataEntry>();
    return _metadataMap[outputUnit].putIfAbsent(printed, () {
      return new _BoundMetadataEntry(node);
    });
  }

  jsAst.Expression _computeTypeRepresentation(DartType type,
      {ignoreTypeVariables: false}) {
    jsAst.Expression representation =
        _rtiEncoder.getTypeRepresentation(_emitter, type, (variable) {
      if (ignoreTypeVariables) return new jsAst.LiteralNull();
      return _typeVariableCodegenAnalysis.reifyTypeVariable(variable.element);
    }, (ResolutionTypedefType typedef) {
      return _mirrorsData.isTypedefAccessibleByReflection(typedef.element);
    });

    if (representation is jsAst.LiteralString) {
      // We don't want the representation to be a string, since we use
      // strings as indicator for non-initialized types in the lazy emitter.
      reporter.internalError(
          NO_LOCATION_SPANNABLE, 'reified types should not be strings.');
    }

    return representation;
  }

  jsAst.Expression addTypeInOutputUnit(DartType type, OutputUnit outputUnit,
      {ignoreTypeVariables: false}) {
    _typesMap[outputUnit] ??= new Map<DartType, _BoundMetadataEntry>();
    return _typesMap[outputUnit].putIfAbsent(type, () {
      return new _BoundMetadataEntry(_computeTypeRepresentation(type,
          ignoreTypeVariables: ignoreTypeVariables));
    });
  }

  List<jsAst.DeferredNumber> computeMetadata(
      MethodElement element, OutputUnit outputUnit) {
    return reporter.withCurrentElement(element, () {
      if (!_mustEmitMetadataForMember(element))
        return const <jsAst.DeferredNumber>[];
      List<jsAst.DeferredNumber> metadata = <jsAst.DeferredNumber>[];
      for (MetadataAnnotation annotation in element.metadata) {
        metadata.add(reifyMetadata(annotation, outputUnit));
      }
      return metadata;
    });
  }

  @override
  void finalizeTokens() {
    bool checkTokensInTypes(OutputUnit outputUnit, entries) {
      UnBoundDebugger debugger = new UnBoundDebugger(outputUnit);
      for (_BoundMetadataEntry entry in entries) {
        if (!entry.isUsed) continue;
        if (debugger.findUnboundPlaceholders(entry.entry)) {
          return false;
        }
      }
      return true;
    }

    void countTokensInTypes(Iterable<_BoundMetadataEntry> entries) {
      jsAst.TokenCounter counter = new jsAst.TokenCounter();
      entries
          .where((_BoundMetadataEntry e) => e._rc > 0)
          .map((_BoundMetadataEntry e) => e.entry)
          .forEach(counter.countTokens);
    }

    jsAst.ArrayInitializer finalizeMap(Map<dynamic, _BoundMetadataEntry> map) {
      bool isUsed(_BoundMetadataEntry entry) => entry.isUsed;
      List<_BoundMetadataEntry> entries = map.values.where(isUsed).toList();
      entries.sort();

      // TODO(herhut): Bucket entries by index length and use a stable
      //               distribution within buckets.
      int count = 0;
      for (_BoundMetadataEntry entry in entries) {
        entry.finalize(count++);
      }

      List<jsAst.Node> values =
          entries.map((_BoundMetadataEntry e) => e.entry).toList();

      return new jsAst.ArrayInitializer(values);
    }

    _metadataTokens.forEach((OutputUnit outputUnit, _MetadataList token) {
      Map metadataMap = _metadataMap[outputUnit];
      if (metadataMap != null) {
        token.setExpression(finalizeMap(metadataMap));
      } else {
        token.setExpression(new jsAst.ArrayInitializer([]));
      }
    });

    _typesTokens.forEach((OutputUnit outputUnit, _MetadataList token) {
      Map typesMap = _typesMap[outputUnit];
      if (typesMap != null) {
        assert(checkTokensInTypes(outputUnit, typesMap.values));
        countTokensInTypes(typesMap.values);
        token.setExpression(finalizeMap(typesMap));
      } else {
        token.setExpression(new jsAst.ArrayInitializer([]));
      }
    });
  }
}

class UnBoundDebugger extends jsAst.BaseVisitor {
  OutputUnit outputUnit;
  bool _foundUnboundToken = false;

  UnBoundDebugger(this.outputUnit);

  @override
  visitDeferredNumber(jsAst.DeferredNumber token) {
    if (token is _ForwardingMetadataEntry && !token.isBound) {
      _foundUnboundToken = true;
    }
  }

  bool findUnboundPlaceholders(jsAst.Node node) {
    node.accept(this);
    return _foundUnboundToken;
  }
}
