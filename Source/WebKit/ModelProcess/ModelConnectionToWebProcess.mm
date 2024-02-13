/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ModelConnectionToWebProcess.h"

#if ENABLE(MODEL_PROCESS)

#include "DataReference.h"
#include "LayerHostingContext.h"
#include "Logging.h"
#include "MessageSenderInlines.h"
#include "ModelConnectionToWebProcessMessages.h"
#include "ModelProcess.h"
#include "ModelProcessConnectionInfo.h"
#include "ModelProcessConnectionMessages.h"
#include "ModelProcessConnectionParameters.h"
#include "ModelProcessMessages.h"
#include "ModelProcessProxyMessages.h"
#include "WebCoreArgumentCoders.h"
#include "WebErrors.h"
#include "WebProcessMessages.h"
#include <WebCore/LogInitialization.h>

#if ENABLE(IPC_TESTING_API)
#include "IPCTesterMessages.h"
#endif

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, (&connection()))

namespace WebKit {
using namespace WebCore;

Ref<ModelConnectionToWebProcess> ModelConnectionToWebProcess::create(ModelProcess& modelProcess, WebCore::ProcessIdentifier webProcessIdentifier, PAL::SessionID sessionID, IPC::Connection::Handle&& connectionHandle, ModelProcessConnectionParameters&& parameters)
{
    return adoptRef(*new ModelConnectionToWebProcess(modelProcess, webProcessIdentifier, sessionID, WTFMove(connectionHandle), WTFMove(parameters)));
}

ModelConnectionToWebProcess::ModelConnectionToWebProcess(ModelProcess& modelProcess, WebCore::ProcessIdentifier webProcessIdentifier, PAL::SessionID sessionID, IPC::Connection::Handle&& connectionHandle, ModelProcessConnectionParameters&& parameters)
    : m_connection(IPC::Connection::createClientConnection(IPC::Connection::Identifier { WTFMove(connectionHandle) }))
    , m_modelProcess(modelProcess)
    , m_webProcessIdentifier(webProcessIdentifier)
    , m_webProcessIdentity(WTFMove(parameters.webProcessIdentity))
    , m_sessionID(sessionID)
#if HAVE(AUDIT_TOKEN)
    , m_presentingApplicationAuditToken(parameters.presentingApplicationAuditToken ? std::optional(parameters.presentingApplicationAuditToken->auditToken()) : std::nullopt)
#endif
{
    RELEASE_ASSERT(RunLoop::isMain());

    // Use this flag to force synchronous messages to be treated as asynchronous messages in the WebProcess.
    // Otherwise, the WebProcess would process incoming synchronous IPC while waiting for a synchronous IPC
    // reply from the model process, which would be unsafe.
    m_connection->setOnlySendMessagesAsDispatchWhenWaitingForSyncReplyWhenProcessingSuchAMessage(true);
    m_connection->open(*this);

    WebKit::ModelProcessConnectionInfo info {
#if HAVE(AUDIT_TOKEN)
        modelProcess.parentProcessConnection()->getAuditToken(),
#endif
    };
    m_connection->send(Messages::ModelProcessConnection::DidInitialize(info), 0);
    ++gObjectCountForTesting;
}

ModelConnectionToWebProcess::~ModelConnectionToWebProcess()
{
    RELEASE_ASSERT(RunLoop::isMain());

    m_connection->invalidate();

    --gObjectCountForTesting;
}

uint64_t ModelConnectionToWebProcess::gObjectCountForTesting = 0;

void ModelConnectionToWebProcess::didClose(IPC::Connection& connection)
{
    modelProcess().connectionToWebProcessClosed(connection);
    modelProcess().removeModelConnectionToWebProcess(*this); // May destroy |this|.
}

#if HAVE(VISIBILITY_PROPAGATION_VIEW)
void ModelConnectionToWebProcess::createVisibilityPropagationContextForPage(WebPageProxyIdentifier pageProxyID, WebCore::PageIdentifier pageID, bool canShowWhileLocked)
{
    auto contextForVisibilityPropagation = LayerHostingContext::createForExternalHostingProcess({ canShowWhileLocked });
    RELEASE_LOG(Process, "ModelConnectionToWebProcess::createVisibilityPropagationContextForPage: pageProxyID=%" PRIu64 ", webPageID=%" PRIu64 ", contextID=%u", pageProxyID.toUInt64(), pageID.toUInt64(), contextForVisibilityPropagation->contextID());
    modelProcess().send(Messages::ModelProcessProxy::DidCreateContextForVisibilityPropagation(pageProxyID, pageID, contextForVisibilityPropagation->contextID()));
    m_visibilityPropagationContexts.add(std::make_pair(pageProxyID, pageID), WTFMove(contextForVisibilityPropagation));
}

void ModelConnectionToWebProcess::destroyVisibilityPropagationContextForPage(WebPageProxyIdentifier pageProxyID, WebCore::PageIdentifier pageID)
{
    RELEASE_LOG(Process, "ModelConnectionToWebProcess::destroyVisibilityPropagationContextForPage: pageProxyID=%" PRIu64 ", webPageID=%" PRIu64, pageProxyID.toUInt64(), pageID.toUInt64());

    auto key = std::make_pair(pageProxyID, pageID);
    ASSERT(m_visibilityPropagationContexts.contains(key));
    m_visibilityPropagationContexts.remove(key);
}
#endif

void ModelConnectionToWebProcess::configureLoggingChannel(const String& channelName, WTFLogChannelState state, WTFLogLevel level)
{
#if !RELEASE_LOG_DISABLED
    if  (auto* channel = WebCore::getLogChannel(channelName)) {
        channel->state = state;
        channel->level = level;
    }

    auto* channel = getLogChannel(channelName);
    if  (!channel)
        return;

    channel->state = state;
    channel->level = level;
#else
    UNUSED_PARAM(channelName);
    UNUSED_PARAM(state);
    UNUSED_PARAM(level);
#endif
}

void ModelConnectionToWebProcess::requestHostingContextID(RenderingBackendIdentifier identifier, CompletionHandler<void(LayerHostingContextID)>&& completionHandler)
{
    RELEASE_LOG(Process, "EDDYEDDY requestHostingContextID");
    
    LayerHostingContextID ctxId;
    auto addResult = m_tmpModelPlayers.ensure(identifier, [&] () mutable {
        const auto& player = TmpModelPlayer::create();
        ctxId = player->layerHostingContextId();
        RELEASE_LOG(Process, "EDDYEDDY ctxId is now %u", ctxId);
        return player;
    });
    ASSERT_UNUSED(addResult, addResult.isNewEntry);
    completionHandler(ctxId);
}

void ModelConnectionToWebProcess::loadModel(RenderingBackendIdentifier identifier, Ref<WebCore::Model>&& model)
{
    RELEASE_LOG(Process, "EDDYEDDY ModelConnectionToWebProcess::loadModel: identifier=%llu size=%zu url=%s", identifier.toUInt64(), model->data()->size(), model->url().string().utf8().data());
//    
//    LayerHostingContextID ctxId;
//    auto addResult = m_tmpModelPlayers.ensure(identifier, [&] () mutable {
//        const auto& player = TmpModelPlayer::create();
//        player->load(WTFMove(model));
//        ctxId = player->layerHostingContextId();
//        RELEASE_LOG(Process, "EDDYEDDY ctxId is now %u", ctxId);
//        return player;
//    });
//    ASSERT_UNUSED(addResult, addResult.isNewEntry);
//    if (!addResult.isNewEntry)
//        addResult.iterator->value = addResult.iterator->value + "\n; "_s + string;
//
//    m_connection->send(Messages::ModelProcessConnection::LayerHostingContextIdChanged(identifier, ctxId), 0);
}

bool ModelConnectionToWebProcess::allowsExitUnderMemoryPressure() const
{
    // FIXME: Should allow exit if we have no models.
    return false;
}

Logger& ModelConnectionToWebProcess::logger()
{
    if (!m_logger) {
        m_logger = Logger::create(this);
        m_logger->setEnabled(this, m_sessionID.isAlwaysOnLoggingAllowed());
    }

    return *m_logger;
}

void ModelConnectionToWebProcess::didReceiveInvalidMessage(IPC::Connection& connection, IPC::MessageName messageName)
{
#if ENABLE(IPC_TESTING_API)
    if (connection.ignoreInvalidMessageForTesting())
        return;
#endif
    RELEASE_LOG_FAULT(IPC, "Received an invalid message '%" PUBLIC_LOG_STRING "' from WebContent process %" PRIu64 ".", description(messageName), m_webProcessIdentifier.toUInt64());
}

void ModelConnectionToWebProcess::lowMemoryHandler(Critical critical, Synchronous synchronous)
{
}

bool ModelConnectionToWebProcess::dispatchMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
#if ENABLE(IPC_TESTING_API)
    if (decoder.messageReceiverName() == Messages::IPCTester::messageReceiverName()) {
        m_ipcTester.didReceiveMessage(connection, decoder);
        return true;
    }
#endif

    return messageReceiverMap().dispatchMessage(connection, decoder);
}

bool ModelConnectionToWebProcess::dispatchSyncMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& replyEncoder)
{
#if ENABLE(IPC_TESTING_API)
    if (decoder.messageReceiverName() == Messages::IPCTester::messageReceiverName()) {
        m_ipcTester.didReceiveSyncMessage(connection, decoder, replyEncoder);
        return true;
    }
#endif
    return messageReceiverMap().dispatchSyncMessage(connection, decoder, replyEncoder);
}

} // namespace WebKit

#undef MESSAGE_CHECK


















// We have to link in CoreRE this way for WKA. When this gets merged back
// to OpenSource, we should link this in properly via configuration.
//asm(".linker_option \"-framework\", \"CoreRE\"");

namespace WebKit {

Ref<TmpModelPlayer> TmpModelPlayer::create()
{
    return adoptRef(*new TmpModelPlayer());
}

TmpModelPlayer::TmpModelPlayer()
{
    m_layer = adoptNS([[CALayer alloc] init]);
    [m_layer setBackgroundColor:cachedCGColor(Color::green).get()];
    [m_layer setFrame:CGRectMake(0, 0, 100, 100)];
    
    LayerHostingContextOptions contextOptions;
    m_inlineLayerHostingContext = LayerHostingContext::createForExternalHostingProcess(contextOptions);
    m_inlineLayerHostingContext->setRootLayer(m_layer.get());
}

TmpModelPlayer::~TmpModelPlayer()
{
//    if (m_loader)
//        m_loader->cancel();
}

void TmpModelPlayer::load(WebCore::Model& model)
{
    //m_loader = WebCore::loadREModel(model, *this);
}
//
//void SeparatedModelPlayer::setLayer(WKSeparatedModelLayer *layer)
//{
//    m_layer = layer;
//}
//
//WKSeparatedModelLayer *SeparatedModelPlayer::layer() const
//{
//    return (WKSeparatedModelLayer *)m_layer;
//}
//
//static inline simd_float2 makeMeterSizeFromPointSize(CGSize pointSize, CGFloat pointsPerMeter)
//{
//    return simd_make_float2(pointSize.width / pointsPerMeter, pointSize.height / pointsPerMeter);
//}
//
//static simd_float3 computeExtents(simd_float2 boundsOfLayerInMeters, simd_float3 originalBoundingBoxExtents)
//{
//    if (simd_reduce_min(originalBoundingBoxExtents) - FLT_EPSILON > 0) {
//        auto boundsScaleRatios = simd_make_float2(
//            boundsOfLayerInMeters.x / originalBoundingBoxExtents.x,
//            boundsOfLayerInMeters.y / originalBoundingBoxExtents.y
//        );
//        return simd_reduce_min(boundsScaleRatios) * originalBoundingBoxExtents;
//    }
//
//    return originalBoundingBoxExtents;
//}
//
//static CGFloat degreesToRadians(CGFloat degrees)
//{
//    return degrees * 3.14159 / 180;
//}
//
//static RESRT computeSRT(CALayer *layer, simd_float3 originalBoundingBoxExtents, float pitch, float yaw, bool isPortal, CGFloat pointsPerMeter)
//{
//    auto boundsOfLayerInMeters = makeMeterSizeFromPointSize(layer.bounds.size, pointsPerMeter);
//    auto extents = computeExtents(boundsOfLayerInMeters, originalBoundingBoxExtents);
//
//    RESRT srt;
//    srt.scale = simd_make_float3(extents.x / originalBoundingBoxExtents.x, extents.y / originalBoundingBoxExtents.y, extents.z / originalBoundingBoxExtents.z);
//
//    // Must be normalized, but these obviously are.
//    simd_float3 xAxis = simd_make_float3(1, 0, 0);
//    simd_float3 yAxis = simd_make_float3(0, 1, 0);
//
//    // FIXME: These should rotate around the center point of the model.
//    simd_quatf pitchQuat = simd_quaternion(degreesToRadians(pitch), xAxis);
//    simd_quatf yawQuat = simd_quaternion(degreesToRadians(yaw), yAxis);
//    srt.rotation = simd_mul(pitchQuat, yawQuat);
//
//    if (isPortal)
//        srt.translation = simd_make_float3(0, -boundsOfLayerInMeters.y / 2.0f, -extents.z / 2.0f);
//    else
//        srt.translation = simd_make_float3(0, -boundsOfLayerInMeters.y / 2.0f, extents.z / 2.0f);
//
//    return srt;
//}
//
//CGFloat SeparatedModelPlayer::effectivePointsPerMeter()
//{
//    constexpr CGFloat defaultPointsPerMeter = 1000;
//
//    CALayer *layer = this->layer();
//    do {
//        if (CGFloat pointsPerMeter = [[layer valueForKeyPath:@"separatedOptions.pointsPerMeter"] floatValue])
//            return pointsPerMeter;
//        layer = layer.superlayer;
//    } while (layer);
//
//    return defaultPointsPerMeter;
//}
//
//void SeparatedModelPlayer::updateTransform()
//{
//    if (!m_model)
//        return;
//
//    // FIXME: Use the value of the 'object-fit' property here to compute an appropriate SRT.
//    RESRT newSRT = computeSRT((WKSeparatedModelLayer *)m_layer, m_originalBoundingBoxExtents, m_pitch, m_yaw, [m_layer isPortal], effectivePointsPerMeter());
//
//    auto transform = REEntityGetOrAddComponentByClass(m_model->rootEntity(), RETransformComponentGetComponentType());
//    RETransformComponentSetLocalSRT(transform, newSRT);
//    RENetworkMarkComponentDirty(transform);
//}
//
//void SeparatedModelPlayer::updateOpacity()
//{
//    if (!m_model)
//        return;
//
//    auto opacity = std::max(0.0f, [m_layer opacity]);
//
//    if (opacity >= 1.0f) {
//        // If the hosting layer is completely opaque, remove any fade component that might have been set
//        // previously.
//        REEntityRemoveComponentByClass(m_model->rootEntity(), REHierarchicalFadeComponentGetComponentType());
//        // FIXME: Do we need to mark anything as dirty when removing a component?
//        return;
//    }
//
//    auto hierarchicalFadeComponent = REEntityGetOrAddComponentByClass(m_model->rootEntity(), REHierarchicalFadeComponentGetComponentType());
//    REHierarchicalFadeComponentSetOpacity(hierarchicalFadeComponent, opacity);
//    RENetworkMarkComponentDirty(hierarchicalFadeComponent);
//}
//
//void SeparatedModelPlayer::didMoveToWindow()
//{
//    updateTransform();
//}
//
//void SeparatedModelPlayer::startAnimating()
//{
//    if (!m_model)
//        return;
//
//    auto animationLibraryComponent = REEntityGetComponentByClass(m_model->rootEntity(), REAnimationLibraryComponentGetComponentType());
//    if (!animationLibraryComponent)
//        return;
//
//    auto animationLibraryAsset = REAnimationLibraryComponentGetAnimationLibraryAsset(animationLibraryComponent);
//    if (!animationLibraryAsset)
//        return;
//
//    auto engine = REEngineGetShared();
//    auto serviceLocator = REEngineGetServiceLocator(engine);
//    auto assetManager = REServiceLocatorGetAssetManager(serviceLocator);
//
//    auto animationLibraryDefinition = adoptRE(REAnimationLibraryDefinitionCreateFromAnimationLibraryAsset(assetManager, animationLibraryAsset));
//    if (!animationLibraryDefinition)
//        return;
//
//    // FIXME: Allow passing in the name of the animtion to run, and then loop over all the
//    // entries in the animationLibraryDefinition, extracting the root timelines and getting
//    // their names via RETimelineDefinitionGetName().
//
//    auto animationAsset = REAnimationLibraryDefinitionGetEntryAsset(animationLibraryDefinition.get(), 0);
//    if (!animationAsset)
//        return;
//
//    auto extractRootTimelineDefinition = [] (auto animationAsset) -> REPtr<RETimelineDefinitionRef> {
//        auto animationAssetType = REAssetHandleAssetType(animationAsset);
//        if (animationAssetType == kREAssetTypeTimeline) {
//            return adoptRE(RETimelineDefinitionCreateFromTimeline(animationAsset));
//        } else if (animationAssetType == kREAssetTypeAnimationScene) {
//            auto rootTimelineAsset = REAnimationSceneAssetGetRootTimeline(animationAsset);
//            return adoptRE(RETimelineDefinitionCreateFromTimeline(rootTimelineAsset));
//        }
//        return nullptr;
//    };
//    
//    auto rootTimelineDefinition = extractRootTimelineDefinition(animationAsset);
//    if (!rootTimelineDefinition) {
//        NSLog(@"SeparatedModelPlayer Could not extract root timeline from animation asset due to unknown asset type: %@", (NSString *)REAssetGetType(animationAsset));
//        return;
//    }
//
//    // FIXME: Allow passing in options to control looping behavior.
//
//    // Wrap animation asset in an infinitely repeating clip.
//
//    auto repeatingTimelineClipDefinition = adoptRE(RETimelineDefinitionCreateTimelineClip("Repeater", assetManager, rootTimelineDefinition.get()));
//    RETimelineDefinitionSetClipLoopBehavior(repeatingTimelineClipDefinition.get(), kREAnimationLoopBehaviorRepeat);
//    double duration = std::numeric_limits<double>::infinity();
//    RETimelineDefinitionSetClipDuration(repeatingTimelineClipDefinition.get(), &duration);
//    auto repeatingTimelineAsset = adoptRE(RETimelineDefinitionCreateTimelineAsset(repeatingTimelineClipDefinition.get(), assetManager));
//
//    auto animationComponent = REEntityGetOrAddComponentByClass(m_model->rootEntity(), REAnimationComponentGetComponentType());
//    auto animationHandoffDescription = REAnimationHandoffDefaultDescEx();
//    m_animationPlaybackToken = REAnimationComponentPlay(animationComponent, repeatingTimelineAsset.get(), animationHandoffDescription, kREAnimationMarkComponentsDirty);
//}
//
//void SeparatedModelPlayer::didFinishLoading(WebCore::REModelLoader& loader, Ref<WebCore::REModel> model)
//{
//    dispatch_assert_queue(dispatch_get_main_queue());
//    ASSERT(&loader == m_loader.get());
//
//    m_loader = nullptr;
//    m_model = WTFMove(model);
//
//    auto modelBoundingBox = REEntityComputeMeshBounds(m_model->rootEntity(), true, matrix_identity_float4x4, kREEntityStatusNone);
//    m_originalBoundingBoxExtents = REAABBExtents(modelBoundingBox);
//
//    REEntitySubtreeAddNetworkComponentRecursive(m_model->rootEntity());
//
//    auto clientComponent = RECALayerGetCALayerClientComponent(layer());
//    auto rootEntity = REComponentGetEntity(clientComponent);
//
//    REEntitySetParent(m_model->rootEntity(), rootEntity);
//
//    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DumpModelsOnLoad"]) {
//        TextStream ts(TextStream::LineMode::MultipleLine);
//        TextStream::GroupScope scope(ts);
//        dumpSeparatedLayerProperties(ts, layer());
//        NSLog(@"Dump for %@\n:%@", (NSURL *)m_model->modelSource().url(), (NSString *)ts.release());
//    }
//
//    updateTransform();
//    updateOpacity();
//    startAnimating();
//}
//
//void SeparatedModelPlayer::didFailLoading(WebCore::REModelLoader& loader, const WebCore::ResourceError& error)
//{
//    dispatch_assert_queue(dispatch_get_main_queue());
//    ASSERT(&loader == m_loader.get());
//
//    m_loader = nullptr;
//
//    if (NSURL *url = error.nsError().userInfo[NSURLErrorFailingURLErrorKey])
//        NSLog(@"WebKit::SeparatedModelPlayer - Model failed to load with error \"%@\" (%@).", error.nsError().localizedDescription, url);
//    else
//        NSLog(@"WebKit::SeparatedModelPlayer - Model failed to load with error \"%@\".", error.nsError().localizedDescription);
//
//    // FIXME: Do something sensible in the failure case.
//}

}






#endif // ENABLE(MODEL_PROCESS)



