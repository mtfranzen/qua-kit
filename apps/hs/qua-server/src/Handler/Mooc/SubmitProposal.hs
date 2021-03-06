-----------------------------------------------------------------------------
-- |
-- Module      :  Handler.Mooc.SubmitProposal
-- Copyright   :  (c) Artem Chirkin
-- License     :  MIT
--
-- Maintainer  :  Artem Chirkin <chirkin@arch.ethz.ch>
-- Stability   :  experimental
--
--
-----------------------------------------------------------------------------

module Handler.Mooc.SubmitProposal
  ( postSubmitProposalR
  ) where

import Import
import Database.Persist.Sql (toSqlKey)
import Data.Text.Read (decimal)
import Control.Monad.Trans.Maybe
import qualified Data.Text as Text (unpack)
--import Text.Blaze
import Web.LTI

import qualified Data.ByteString.Base64 as BSB (decodeLenient)


-- | Submit a design proposal
--   session params:
--     * qua_view_mode=edit -- means a user works on a scenario in edit mode => can save something
--     * scenario_id -- id of previous submission
--   post params:
--     * geometry    -- geoJSON, obligatory
--     * preview     -- image, obligatory
--     * description -- text, optional

postSubmitProposalR :: Handler Html
postSubmitProposalR = do
    Entity uId user <- requireAuth
    geometry <- encodeUtf8
        <$> requirePostParam "geometry" "Geometry input is not found!"
    preview  <- BSB.decodeLenient . encodeUtf8 . drop 1 . dropWhile (',' /=)
        <$> requirePostParam "preview" "Preview input is not found!"
    description  <- fromMaybe ""
        <$> lookupPostParam "description"

    qua_view_mode <- requireSession "qua_view_mode" "You must be in an 'edit' mode to save scenario."
    when (qua_view_mode /= "edit") $ invalidArgsI ["You must be in an 'edit' mode to save scenario." :: Text]

    tryMaybies resolveBySesScenarioId resolveBySesExerciseId >>= \mscenario -> case mscenario of
        Just prevScenario -> do
          when (uId /= scenarioAuthorId prevScenario) $
            invalidArgsI ["You can work only on your own scenarios!" :: Text]
          t <- liftIO getCurrentTime
          runDB . insert_ $ prevScenario
                 { scenarioImage =  preview
                 , scenarioDescription = description
                 , scenarioGeometry = geometry
                 , scenarioLastUpdate = t
                 }
          setMessage . toHtml $ "Thank you, " <> userName user <> ", your design proposal has been saved."
          redirectUltDest MoocHomeR
        Nothing -> return ()

    completelyNewOne preview geometry description >>= \mscenarioId -> case mscenarioId of
        Just i -> do
          setMessage . preEscapedToMarkup $
              "Thank you, " <> userName user <> ", your design proposal has been saved.<br>"
              <> "Now you can come back to edX or stay at qua-kit and explore submissions of other students.<br>"
              <> "<p class=\"text-brand-accent\"><b>Note!</b><br>We identified you via a special link on edX (when you pressed \"Go!\" button). "
              <> "You can come back and continue the work at the current state by going on the same link (button).<br>"
              <> "We sent to edX your base grade (60% of maximum); the grade will be updated as soon"
              <> " as other students start to vote and discuss your submission.</p>"
          msc <- runDB $ get i
          case (,) <$> (msc >>= scenarioEdxResultId)  <*> (msc >>= scenarioEdxOutcomeUrl) of
            Nothing -> return ()
            Just (sourcedId, outcomeUrl) -> do
              ye <- getYesod
              req <- replaceResultRequest (appLTICredentials $ appSettings ye) (Text.unpack outcomeUrl) sourcedId 0.6 Nothing
              _ <- httpNoBody req
              return ()
          redirectUltDest MoocHomeR
        Nothing -> invalidArgsI ["Some error occurred. Consult the developer team." :: Text]
  where
    tryMaybies m1 m2 = m1 >>= \mv1 -> case mv1 of
                          Nothing -> m2
                          Just _ -> return mv1


resolveBySesScenarioId :: Handler (Maybe Scenario)
resolveBySesScenarioId = runMaybeT $ do
  mescenario_id   <- fmap decimal . MaybeT $ lookupSession "scenario_id"
  deleteSession "scenario_id"
  case mescenario_id of
    Right (i,_) -> MaybeT . runDB . get $ toSqlKey i
    _ -> MaybeT $ return Nothing

resolveBySesExerciseId :: Handler (Maybe Scenario)
resolveBySesExerciseId = runMaybeT $ do
  userId <- MaybeT maybeAuthId
  mscp_id   <- lift $ lookupSession "custom_exercise_id"
  fmap entityVal . MaybeT . runDB $ selectSource
                        (case decimal <$> mscp_id of
                           Just (Right (i,_))   -> [ ScenarioAuthorId ==. userId
                                                   , ScenarioTaskId   ==. toSqlKey  i
                                                   ]
                           _ -> [ScenarioAuthorId ==. userId]
                        )
                        [ Desc ScenarioLastUpdate
                        ] $$ await

completelyNewOne :: ByteString -> ByteString -> Text -> Handler (Maybe ScenarioId)
completelyNewOne img geometry desc = runMaybeT $ do
  userId <- MaybeT maybeAuthId
  scp_id            <- MaybeT $ lookupSession "custom_exercise_id"
  scpId <- case decimal scp_id of
            Right (i,_) -> return $ toSqlKey i
            _ -> MaybeT $ return Nothing
  resource_link_id  <- MaybeT $ lookupSession "resource_link_id"
  lis_outcome_service_url <- lift $ lookupSession "lis_outcome_service_url"
  lis_result_sourcedid    <- lift $ lookupSession "lis_result_sourcedid"
  MaybeT . runDB . runMaybeT $ do
    (scproblem, edxres) <- MaybeT $ (\mx my -> (,) <$> mx <*> my)
                                 <$> get scpId
                                 <*> getBy (EdxResLinkId resource_link_id)
    t <- liftIO getCurrentTime
    lift . insert $ Scenario userId scpId
                     img
                     geometry
                     desc
                     (scenarioProblemScale scproblem)
                     (entityKey edxres)
                     lis_outcome_service_url
                     lis_result_sourcedid
                     t

