import 'package:apidash/services/websocket_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../consts.dart';
import '../models/models.dart';
import '../services/services.dart' show hiveHandler, HiveHandler, request;
import '../utils/utils.dart' show uuid, collectionToHAR;
import 'settings_providers.dart';
import 'ui_providers.dart';

final selectedIdStateProvider = StateProvider<String?>((ref) => null);

final selectedRequestModelProvider = StateProvider<RequestModel?>((ref) {
  final selectedId = ref.watch(selectedIdStateProvider);
  final collection = ref.watch(collectionStateNotifierProvider);
  if (selectedId == null || collection == null) {
    return null;
  } else {
    return collection[selectedId];
  }
});

final requestSequenceProvider = StateProvider<List<String>>((ref) {
  var ids = hiveHandler.getIds();
  return ids ?? [];
});

final StateNotifierProvider<CollectionStateNotifier, Map<String, RequestModel>?>
    collectionStateNotifierProvider =
    StateNotifierProvider((ref) => CollectionStateNotifier(ref, hiveHandler));

class CollectionStateNotifier
    extends StateNotifier<Map<String, RequestModel>?> {
  CollectionStateNotifier(this.ref, this.hiveHandler) : super(null) {
    var status = loadData();
    Future.microtask(() {
      if (status) {
        ref.read(requestSequenceProvider.notifier).state = [
          state!.keys.first,
        ];
      }
      ref.read(selectedIdStateProvider.notifier).state =
          ref.read(requestSequenceProvider)[0];
    });
  }

  final Ref ref;
  final HiveHandler hiveHandler;
  final baseResponseModel = const ResponseModel();

  bool hasId(String id) => state?.keys.contains(id) ?? false;

  RequestModel? getRequestModel(String id) {
    return state?[id];
  }

  void add() {
    final id = uuid.v1();
    final newRequestModel = RequestModel(
      id: id,
    );
    var map = {...state!};
    map[id] = newRequestModel;
    state = map;
    ref
        .read(requestSequenceProvider.notifier)
        .update((state) => [id, ...state]);
    ref.read(selectedIdStateProvider.notifier).state = newRequestModel.id;
  }

  void reorder(int oldIdx, int newIdx) {
    var itemIds = ref.read(requestSequenceProvider);
    final itemId = itemIds.removeAt(oldIdx);
    itemIds.insert(newIdx, itemId);
    ref.read(requestSequenceProvider.notifier).state = [...itemIds];
  }

  void remove(String id) {
    var itemIds = ref.read(requestSequenceProvider);
    int idx = itemIds.indexOf(id);
    itemIds.remove(id);
    ref.read(requestSequenceProvider.notifier).state = [...itemIds];

    String? newId;
    if (idx == 0 && itemIds.isNotEmpty) {
      newId = itemIds[0];
    } else if (itemIds.length > 1) {
      newId = itemIds[idx - 1];
    } else {
      newId = null;
    }

    ref.read(selectedIdStateProvider.notifier).state = newId;

    var map = {...state!};
    map.remove(id);
    state = map;
  }

  void duplicate(String id) {
    final newId = uuid.v1();

    var itemIds = ref.read(requestSequenceProvider);
    int idx = itemIds.indexOf(id);

    final newModel = state![id]!.duplicate(
      id: newId,
    );

    itemIds.insert(idx + 1, newId);
    var map = {...state!};
    map[newId] = newModel;
    state = map;

    ref.read(requestSequenceProvider.notifier).state = [...itemIds];
    ref.read(selectedIdStateProvider.notifier).state = newId;
  }

  void update(
    String id, {
    Protocol? protocol,
    HTTPVerb? method,
    String? url,
    String? name,
    String? description,
    int? requestTabIndex,
    List<NameValueModel>? requestHeaders,
    List<NameValueModel>? requestParams,
    List<bool>? isHeaderEnabledList,
    List<bool>? isParamEnabledList,
    ContentType? requestBodyContentType,
    String? requestBody,
    List<FormDataModel>? requestFormDataList,
    int? responseStatus,
    String? message,
    ResponseModel? responseModel,
  }) {
    final newModel = state![id]!.copyWith(
        protocol: protocol,
        method: method,
        url: url,
        name: name,
        description: description,
        requestTabIndex: requestTabIndex,
        requestHeaders: requestHeaders,
        requestParams: requestParams,
        isHeaderEnabledList: isHeaderEnabledList,
        isParamEnabledList: isParamEnabledList,
        requestBodyContentType: requestBodyContentType,
        requestBody: requestBody,
        requestFormDataList: requestFormDataList,
        responseStatus: responseStatus,
        message: message,
        responseModel: responseModel);

    var map = {...state!};
    map[id] = newModel;
    state = map;
  }

  WebSocketManager createWebSocketManager(
      {required String url, required String id}) {
    final webSocketManager = WebSocketManager(
      addMessage: (String message, WebSocketMessageType type) {
        ref
            .read(collectionStateNotifierProvider.notifier)
            .addWebSocketMessage(message, type, id);
      },
    );
    ref.onDispose(() => webSocketManager.disconnect(url));

    return webSocketManager;
  }

  Future<void> connectWebSocket(String id) async {
    ref.read(sentRequestIdStateProvider.notifier).state = id;
    ref.read(codePaneVisibleStateProvider.notifier).state = false;

    RequestModel requestModel = state![id]!;

    final newRequestModel = requestModel.copyWith(
        webSocketManager:
            createWebSocketManager(url: requestModel.url, id: id));
    newRequestModel.webSocketManager!.connect(requestModel.url);

    ref.read(sentRequestIdStateProvider.notifier).state = null;
    var map = {...state!};
    map[id] = newRequestModel;
    state = map;
  }

  Future<void> disconnectWebSocket(String id) async {
    ref.read(sentRequestIdStateProvider.notifier).state = id;
    ref.read(codePaneVisibleStateProvider.notifier).state = false;

    RequestModel requestModel = state![id]!;

    requestModel.webSocketManager?.disconnect(requestModel.url);

    ref.read(sentRequestIdStateProvider.notifier).state = null;
  }

  Future<void> sendWebSocketRequest(String id) async {
    ref.read(sentRequestIdStateProvider.notifier).state = id;
    ref.read(codePaneVisibleStateProvider.notifier).state = false;

    RequestModel requestModel = state![id]!;

    if (requestModel.webSocketManager == null) {
      await connectWebSocket(id);
      requestModel = state![id]!;
    }

    ref.read(collectionStateNotifierProvider.notifier).addWebSocketMessage(
        requestModel.message!, WebSocketMessageType.client, id);
    requestModel.webSocketManager!.sendMessage(requestModel.message!);

    ref.read(sentRequestIdStateProvider.notifier).state = null;
  }

  void addWebSocketMessage(
      String message, WebSocketMessageType type, String id) {
    var map = {...state!};
    if (state?[id] != null) {
      map[id] = state![id]!.copyWith(
        webSocketMessages: [
          WebSocketMessage(message, DateTime.now(), type),
          ...?state![id]!.webSocketMessages,
        ],
      );
    }
    state = map;
  }

  void deleteWebSocketMessages() {
    final selectedId = ref.read(selectedIdStateProvider.notifier).state;

    var map = {...state!};
    map[selectedId!] = state![selectedId]!.copyWith(
      webSocketMessages: [],
    );
    state = map;
  }

  bool isWebSocketConnected() {
    final selectedId = ref.read(selectedIdStateProvider.notifier).state;
    RequestModel requestModel = state![selectedId]!;

    return requestModel.webSocketManager?.channel != null;
  }

  Future<void> sendRequest(String id) async {
    ref.read(sentRequestIdStateProvider.notifier).state = id;
    ref.read(codePaneVisibleStateProvider.notifier).state = false;
    final defaultUriScheme =
        ref.read(settingsProvider.select((value) => value.defaultUriScheme));
    RequestModel requestModel = state![id]!;
    (http.Response?, Duration?, String?)? responseRec = await request(
      requestModel,
      defaultUriScheme: defaultUriScheme,
      isMultiPartRequest:
          requestModel.requestBodyContentType == ContentType.formdata,
    );
    late final RequestModel newRequestModel;
    if (responseRec.$1 == null) {
      newRequestModel = requestModel.copyWith(
        responseStatus: -1,
        message: responseRec.$3,
      );
    } else {
      final responseModel = baseResponseModel.fromResponse(
        response: responseRec.$1!,
        time: responseRec.$2!,
      );
      int statusCode = responseRec.$1!.statusCode;
      newRequestModel = requestModel.copyWith(
        responseStatus: statusCode,
        message: kResponseCodeReasons[statusCode],
        responseModel: responseModel,
      );
    }
    ref.read(sentRequestIdStateProvider.notifier).state = null;
    var map = {...state!};
    map[id] = newRequestModel;
    state = map;
  }

  Future<void> clearData() async {
    ref.read(clearDataStateProvider.notifier).state = true;
    ref.read(selectedIdStateProvider.notifier).state = null;
    await hiveHandler.clear();
    ref.read(clearDataStateProvider.notifier).state = false;
    ref.read(requestSequenceProvider.notifier).state = [];
    state = {};
  }

  bool loadData() {
    var ids = hiveHandler.getIds();
    if (ids == null || ids.length == 0) {
      String newId = uuid.v1();
      state = {
        newId: RequestModel(
          id: newId,
        ),
      };
      return true;
    } else {
      Map<String, RequestModel> data = {};
      for (var id in ids) {
        var jsonModel = hiveHandler.getRequestModel(id);
        if (jsonModel != null) {
          var requestModel =
              RequestModel.fromJson(Map<String, dynamic>.from(jsonModel));
          data[id] = requestModel;
        }
      }
      state = data;
      return false;
    }
  }

  Future<void> saveData() async {
    ref.read(saveDataStateProvider.notifier).state = true;
    final saveResponse = ref.read(settingsProvider).saveResponses;
    final ids = ref.read(requestSequenceProvider);
    await hiveHandler.setIds(ids);
    for (var id in ids) {
      await hiveHandler.setRequestModel(
        id,
        state?[id]?.toJson(includeResponse: saveResponse),
      );
    }
    await hiveHandler.removeUnused();
    ref.read(saveDataStateProvider.notifier).state = false;
  }

  Future<Map<String, dynamic>> exportDataToHAR() async {
    var result = await collectionToHAR(state?.values.toList());
    return result;
    // return {
    //   "data": state!.map((e) => e.toJson(includeResponse: false)).toList()
    // };
  }
}
