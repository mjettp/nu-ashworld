module Shared.Special
    exposing
        ( Special
        , SpecialAttr(..)
        , ap
        , decoder
        , encode
        , getter
        , hint
        , inc
        , init
        , initAvailable
        , label
        , urlParser
        )

import Json.Decode as JD exposing (Decoder)
import Json.Encode as JE
import Url.Parser exposing (Parser)


type SpecialAttr
    = Strength
    | Perception
    | Endurance
    | Charisma
    | Intelligence
    | Agility
    | Luck


type alias Special =
    { strength : Int
    , perception : Int
    , endurance : Int
    , charisma : Int
    , intelligence : Int
    , agility : Int
    , luck : Int
    }


urlParser : Parser (SpecialAttr -> a) a
urlParser =
    Url.Parser.oneOf
        [ Url.Parser.map Strength (Url.Parser.s "strength")
        , Url.Parser.map Perception (Url.Parser.s "perception")
        , Url.Parser.map Endurance (Url.Parser.s "endurance")
        , Url.Parser.map Charisma (Url.Parser.s "charisma")
        , Url.Parser.map Intelligence (Url.Parser.s "intelligence")
        , Url.Parser.map Agility (Url.Parser.s "agility")
        , Url.Parser.map Luck (Url.Parser.s "luck")
        ]


label : SpecialAttr -> String
label attr =
    case attr of
        Strength ->
            "Strength"

        Perception ->
            "Perception"

        Endurance ->
            "Endurance"

        Charisma ->
            "Charisma"

        Intelligence ->
            "Intelligence"

        Agility ->
            "Agility"

        Luck ->
            "Luck"


getter : SpecialAttr -> (Special -> Int)
getter attr =
    case attr of
        Strength ->
            .strength

        Perception ->
            .perception

        Endurance ->
            .endurance

        Charisma ->
            .charisma

        Intelligence ->
            .intelligence

        Agility ->
            .agility

        Luck ->
            .luck


hint : SpecialAttr -> Maybe String
hint attr =
    case attr of
        Strength ->
            Just "Does nothing now, but will determine HP in the future"

        Perception ->
            Nothing

        Endurance ->
            Just "Does nothing now, but will determine HP in the future"

        Charisma ->
            Nothing

        Intelligence ->
            Nothing

        Agility ->
            Just "The most important skill right now - determines your AP, which in turn determines the amount of punches you can give each turn in a fight."

        Luck ->
            Nothing


decoder : Decoder Special
decoder =
    JD.map7 Special
        (JD.field "strength" JD.int)
        (JD.field "perception" JD.int)
        (JD.field "endurance" JD.int)
        (JD.field "charisma" JD.int)
        (JD.field "intelligence" JD.int)
        (JD.field "agility" JD.int)
        (JD.field "luck" JD.int)


encode : Special -> JE.Value
encode special =
    JE.object
        [ ( "strength", JE.int special.strength )
        , ( "perception", JE.int special.perception )
        , ( "endurance", JE.int special.endurance )
        , ( "charisma", JE.int special.charisma )
        , ( "intelligence", JE.int special.intelligence )
        , ( "agility", JE.int special.agility )
        , ( "luck", JE.int special.luck )
        ]


{-| <http://fallout.wikia.com/wiki/Primary_statistic#Minimum_and_maximum>
-}
init : Special
init =
    { strength = 1
    , perception = 1
    , endurance = 1
    , charisma = 1
    , intelligence = 1
    , agility = 1
    , luck = 1
    }


{-| <http://fallout.wikia.com/wiki/Fallout_2_primary_statistics#Overview>

Total 40 at the start, minus 1 for each stat (stats can't go below 1) = 40 - 7 = 33

-}
initAvailable : Int
initAvailable =
    33


{-| <http://fallout.wikia.com/wiki/Action_Points#Fallout.2C_Fallout_2_and_Fallout_Tactics>
-}
ap : Special -> Int
ap { agility } =
    5 + (agility // 2)


inc : SpecialAttr -> Int -> Special -> ( Int, Special )
inc attr available special =
    if available > 0 && getter attr special < 10 then
        ( available - 1
        , case attr of
            Strength ->
                { special | strength = special.strength + 1 }

            Perception ->
                { special | perception = special.perception + 1 }

            Endurance ->
                { special | endurance = special.endurance + 1 }

            Charisma ->
                { special | charisma = special.charisma + 1 }

            Intelligence ->
                { special | intelligence = special.intelligence + 1 }

            Agility ->
                { special | agility = special.agility + 1 }

            Luck ->
                { special | luck = special.luck + 1 }
        )
    else
        ( available
        , special
        )
