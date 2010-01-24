{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
-- | An 'Html' data type and associated 'ConvertSuccess' instances. This has
-- useful conversions in web development:
--
-- * Automatic generation of simple HTML documents from 'HtmlObject' (mostly
-- useful for testing, you would never want to actually show them to an end
-- user).
--
-- * Converts to JSON, which gives fully HTML escaped JSON. Very nice for Ajax.
--
-- * Can be used with HStringTemplate.
module Data.Object.Html
    ( -- * Data type
      Html (..)
    , HtmlDoc (..)
    , HtmlFragment (..)
    , HtmlObject
      -- * XML helpers
    , XmlDoc (..)
    , cdata
      -- * Standard 'Object' functions
    , toHtmlObject
    , fromHtmlObject
     -- * Re-export
    , module Data.Object
#if TEST
    , testSuite
#endif
    ) where

import Data.Generics
import Data.Object.Text
import Data.Object.Json
import qualified Data.Text.Lazy as TL
import qualified Data.Text as TS
import Web.Encodings
import Text.StringTemplate.Classes
import Control.Arrow (second)
import Data.Attempt
import Data.Object

#if TEST
import Test.Framework (testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.HUnit hiding (Test)
import Text.StringTemplate
#endif

-- | A single piece of HTML code.
data Html =
    Html TS.Text -- ^ Already encoded HTML.
  | Text TS.Text -- ^ Text which should be HTML escaped.
  | Tag String [(String, String)] Html -- ^ Tag which needs a closing tag.
  | EmptyTag String [(String, String)] -- ^ Tag without a closing tag.
  | HtmlList [Html]
    deriving (Eq, Show, Typeable)

-- | A full HTML document.
newtype HtmlDoc = HtmlDoc { unHtmlDoc :: Text }

type HtmlObject = Object String Html

toHtmlObject :: ConvertSuccess x HtmlObject => x -> HtmlObject
toHtmlObject = cs

fromHtmlObject :: ConvertAttempt HtmlObject x => HtmlObject -> Attempt x
fromHtmlObject = ca

instance ConvertSuccess String Html where
    convertSuccess = Text . cs
instance ConvertSuccess TS.Text Html where
    convertSuccess = Text
instance ConvertSuccess Text Html where
    convertSuccess = Text . cs
$(deriveAttempts
    [ (''String, ''Html)
    , (''Text, ''Html)
    , (''TS.Text, ''Html)
    ])

instance ConvertSuccess String HtmlObject where
    convertSuccess = Scalar . cs
instance ConvertSuccess Text HtmlObject where
    convertSuccess = Scalar . cs
instance ConvertSuccess TS.Text HtmlObject where
    convertSuccess = Scalar . cs
instance ConvertSuccess [(String, String)] HtmlObject where
    convertSuccess = omTO
instance ConvertSuccess [(Text, Text)] HtmlObject where
    convertSuccess = omTO
instance ConvertSuccess [(TS.Text, TS.Text)] HtmlObject where
    convertSuccess = omTO

showAttribs :: [(String, String)] -> String -> String
showAttribs pairs rest = foldr ($) rest $ map helper pairs where
    helper :: (String, String) -> String -> String
    helper (k, v) rest' =
        ' ' : encodeHtml k
        ++ '=' : '"' : encodeHtml v
        ++ '"' : rest'

htmlToText :: Bool -- ^ True to close empty tags like XML, False like HTML
           -> Html
           -> ([TS.Text] -> [TS.Text])
htmlToText _ (Html t) = (:) t
htmlToText _ (Text t) = (:) $ encodeHtml t
htmlToText xml (Tag n as content) = \rest ->
    (cs $ '<' : n)
    : (cs $ showAttribs as ">")
    : (htmlToText xml content
    $ (cs $ '<' : '/' : n)
    : cs ">"
    : rest)
htmlToText xml (EmptyTag n as) = \rest ->
    (cs $ '<' : n )
    : (cs $ showAttribs as (if xml then "/>" else ">"))
    : rest
htmlToText xml (HtmlList l) = \rest ->
    foldr ($) rest $ map (htmlToText xml) l

newtype HtmlFragment = HtmlFragment { unHtmlFragment :: Text }
instance ConvertSuccess Html HtmlFragment where
    convertSuccess h = HtmlFragment . TL.fromChunks . htmlToText False h $ []
instance ConvertSuccess HtmlFragment Html where
    convertSuccess = HtmlList . map Html . TL.toChunks . unHtmlFragment
-- | Not fully typesafe. You must make sure that when converting to this, the
-- 'Html' starts with a tag.
newtype XmlDoc = XmlDoc { unXmlDoc :: Text }
instance ConvertSuccess Html XmlDoc where
    convertSuccess h = XmlDoc $ TL.fromChunks $
        cs "<?xml version='1.0' encoding='utf-8' ?>\n"
        : htmlToText True h []

-- | Wrap an 'Html' in CDATA for XML output.
cdata :: Html -> Html
cdata h = HtmlList
    [ Html $ cs "<![CDATA["
    , h
    , Html $ cs "]]>"
    ]

instance ConvertSuccess Html HtmlDoc where
    convertSuccess h = HtmlDoc $ TL.fromChunks $
        cs "<!DOCTYPE html>\n<html><head><title>HtmlDoc (autogenerated)</title></head><body>"
        : htmlToText False h
        [cs "</body></html>"]

instance ConvertSuccess HtmlObject Html where
    convertSuccess (Scalar h) = h
    convertSuccess (Sequence hs) = Tag "ul" [] $ HtmlList $ map addLi hs
      where
        addLi h = Tag "li" [] $ cs h
    convertSuccess (Mapping pairs) =
        Tag "dl" [] $ HtmlList $ concatMap addDtDd pairs where
            addDtDd (k, v) =
                [ Tag "dt" [] $ Text $ cs k
                , Tag "dd" [] $ cs v
                ]

instance ConvertSuccess HtmlObject HtmlDoc where
    convertSuccess = cs . (cs :: HtmlObject -> Html)

instance ConvertSuccess Html JsonScalar where
    convertSuccess = cs . unHtmlFragment . cs
instance ConvertSuccess HtmlObject JsonObject where
    convertSuccess = mapKeysValues convertSuccess convertSuccess
instance ConvertSuccess HtmlObject JsonDoc where
    convertSuccess = cs . (cs :: HtmlObject -> JsonObject)

$(deriveAttempts
    [ (''Html, ''HtmlFragment)
    , (''Html, ''HtmlDoc)
    , (''Html, ''JsonScalar)
    ])

$(deriveSuccessConvs ''String ''Html
    [''String, ''Text]
    [''Html, ''HtmlFragment])

instance ToSElem HtmlObject where
    toSElem (Scalar h) = STR $ TL.unpack $ unHtmlFragment $ cs h
    toSElem (Sequence hs) = LI $ map toSElem hs
    toSElem (Mapping pairs) = helper $ map (second toSElem) pairs where
        helper :: [(String, SElem b)] -> SElem b
        helper = SM . cs

#if TEST
caseHtmlToText :: Assertion
caseHtmlToText = do
    let actual = Tag "div" [("id", "foo"), ("class", "bar")] $ HtmlList
            [ Html $ cs "<br>Some HTML<br>"
            , Text $ cs "<'this should be escaped'>"
            , EmptyTag "img" [("src", "baz&")]
            ]
    let expected =
            "<div id=\"foo\" class=\"bar\"><br>Some HTML<br>" ++
            "&lt;&#39;this should be escaped&#39;&gt;" ++
            "<img src=\"baz&amp;\"></div>"
    cs actual @?= (cs expected :: Text)

caseStringTemplate :: Assertion
caseStringTemplate = do
    let content = Mapping
            [ ("foo", Sequence [ Scalar $ Html $ cs "<br>"
                               , Scalar $ Text $ cs "<hr>"])
            , ("bar", Scalar $ EmptyTag "img" [("src", "file.jpg")])
            ]
    let temp = newSTMP "foo:$o.foo$,bar:$o.bar$"
    let expected = "foo:<br>&lt;hr&gt;,bar:<img src=\"file.jpg\">"
    expected @=? toString (setAttribute "o" content temp)

caseJson :: Assertion
caseJson = do
    let content = Mapping
            [ ("foo", Sequence [ Scalar $ Html $ cs "<br>"
                               , Scalar $ Text $ cs "<hr>"])
            , ("bar", Scalar $ EmptyTag "img" [("src", "file.jpg")])
            ]
    let expected = "{\"bar\":\"<img src=\\\"file.jpg\\\">\"" ++
                   ",\"foo\":[\"<br>\",\"&lt;hr&gt;\"]" ++
                   "}"
    JsonDoc (cs expected) @=? cs content

testSuite :: Test
testSuite = testGroup "Data.Object.Html"
    [ testCase "caseHtmlToText" caseHtmlToText
    , testCase "caseStringTemplate" caseStringTemplate
    , testCase "caseJson" caseJson
    ]

#endif
