port module Server.Main exposing (main)

import Dict exposing (Dict)
import Extra.Json as EJ
import Json.Decode as JD exposing (Decoder)
import Json.Encode as JE
import Platform
import Random exposing (Generator)
import Server.Fight
import Server.Route as Route exposing (AuthError(..), Route(..), SignupError(..))
import Server.World
import Shared.Fight exposing (Fight, FightResult(..))
import Shared.Password exposing (Auth, Hashed)
import Shared.Player exposing (ServerPlayer)
import Shared.Special exposing (Special, SpecialAttr)
import Shared.World exposing (ServerWorld)
import Time exposing (Posix)


-- GENERAL


port log : String -> Cmd msg



-- PERSISTENCE


port persist : JE.Value -> Cmd msg



-- HTTP


port httpRequests : (JE.Value -> msg) -> Sub msg


port httpResponse : JE.Value -> Cmd msg


sendHttpResponse : JE.Value -> JE.Value -> Cmd msg
sendHttpResponse response value =
    JE.list identity
        [ response
        , JE.string (JE.encode 0 value)
        ]
        |> httpResponse


persistModel : Model -> Cmd msg
persistModel model =
    model
        |> encodeModel
        |> persist



-- TYPES


type alias Flags =
    JE.Value


type alias Model =
    { world : Shared.World.ServerWorld
    }


type Msg
    = HealTick Posix
    | HttpRequest HttpRequestData
    | HttpRequestError JD.Error
    | GeneratedFight ( JE.Value, Maybe FightData )


type alias HttpRequestData =
    { url : String
    , response : JE.Value
    , headers : Dict String String
    }


main : Program Flags Model Msg
main =
    Platform.worker
        { init = init
        , update = updateWithPersist
        , subscriptions = subscriptions
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    case JD.decodeValue modelDecoder flags of
        Ok model ->
            ( model
            , Cmd.none
            )

        Err err ->
            let
                model =
                    { world = { players = Dict.empty }
                    }
            in
            ( model
            , Cmd.batch
                [ persistModel model
                , log (JD.errorToString err)
                ]
            )


updateWithPersist : Msg -> Model -> ( Model, Cmd Msg )
updateWithPersist msg model =
    let
        ( newModel, cmd ) =
            update msg model
    in
    ( newModel
    , Cmd.batch
        [ cmd
        , if model == newModel then
            Cmd.none
          else
            persistModel newModel
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        HttpRequest { url, response, headers } ->
            case Route.fromString url of
                NotFound ->
                    handleNotFound url response model

                Signup ->
                    handleSignup (authHeaders headers) response model

                Login ->
                    handleLogin (authHeaders headers) response model

                Logout ->
                    handleLogout response model

                Refresh ->
                    handleRefresh (authHeaders headers) response model

                RefreshAnonymous ->
                    handleRefreshAnonymous response model

                Attack attackData ->
                    handleAttack (authHeaders headers) attackData response model

                IncSpecialAttr attr ->
                    handleIncSpecialAttr (authHeaders headers) attr response model

        HttpRequestError error ->
            handleHttpRequestError error model

        HealTick timeOfTick ->
            handleHealTick timeOfTick model

        GeneratedFight data ->
            handleAttackWithGeneratedFight data model


authHeaders : Dict String String -> Maybe (Auth Hashed)
authHeaders headers =
    Maybe.map2 Auth
        (Dict.get "x-username" headers)
        (Dict.get "x-hashed-password" headers
            |> Maybe.map Shared.Password.hashedPassword
        )


handleHttpRequestError : JD.Error -> Model -> ( Model, Cmd Msg )
handleHttpRequestError error model =
    ( model
    , log (JD.errorToString error)
    )


handleHealTick : Posix -> Model -> ( Model, Cmd Msg )
handleHealTick timeOfTick model =
    let
        newWorld : ServerWorld
        newWorld =
            model.world
                |> Server.World.healEverybody

        newModel : Model
        newModel =
            model
                |> setWorld newWorld
    in
    ( newModel
    , Cmd.none
    )


getMessageQueue : String -> Model -> ( Model, List String )
getMessageQueue name model =
    let
        queue : List String
        queue =
            Dict.get name model.world.players
                |> Maybe.map .messageQueue
                |> Maybe.withDefault []

        newWorld : ServerWorld
        newWorld =
            model.world
                |> Server.World.emptyPlayerMessageQueue name

        newModel : Model
        newModel =
            model
                |> setWorld newWorld
    in
    ( newModel, queue )


handleNotFound : String -> JE.Value -> Model -> ( Model, Cmd Msg )
handleNotFound url response model =
    ( model
    , Cmd.batch
        [ log ("NotFound: " ++ url)
        , sendHttpResponse response (Route.handlers.notFound.encode url)
        ]
    )


handleSignup : Maybe (Auth Hashed) -> JE.Value -> Model -> ( Model, Cmd Msg )
handleSignup maybeAuth response model =
    maybeAuth
        |> Maybe.map Shared.Password.verify
        |> Maybe.map
            (\{ name, password } ->
                if nameExists name model.world then
                    ( model
                    , sendHttpResponse response
                        (Route.handlers.signup.encodeError NameAlreadyExists)
                    )
                else
                    let
                        newPlayer : ServerPlayer
                        newPlayer =
                            Shared.Player.init name password

                        welcomeMessage : String
                        welcomeMessage =
                            "Welcome, " ++ name ++ "! You start out in the pleasant, if boring, town of Klamath."

                        modelWithPlayer : Model
                        modelWithPlayer =
                            model
                                |> addPlayer newPlayer
                                |> updateWorld (Server.World.addPlayerMessage name welcomeMessage)

                        ( newModel, messageQueue ) =
                            getMessageQueue name modelWithPlayer
                    in
                    ( newModel
                    , sendHttpResponse response
                        (case Route.handlers.signup.response messageQueue name newModel.world of
                            Ok signupResponse ->
                                Route.handlers.signup.encode signupResponse

                            Err signupError ->
                                Route.handlers.signup.encodeError signupError
                        )
                    )
            )
        |> Maybe.withDefault
            ( model
            , sendHttpResponse response
                (Route.handlers.signup.encodeError (AuthError AuthenticationHeadersMissing))
            )


nameExists : String -> ServerWorld -> Bool
nameExists name world =
    world.players
        |> Dict.filter (\_ player -> String.toLower player.name == String.toLower name)
        |> Dict.isEmpty
        |> not


handleLogin : Maybe (Auth Hashed) -> JE.Value -> Model -> ( Model, Cmd Msg )
handleLogin maybeAuth response model =
    maybeAuth
        |> Maybe.map
            (\auth ->
                if Shared.Password.checksOut auth model.world.players then
                    let
                        ( newModel, messageQueue ) =
                            getMessageQueue auth.name model
                    in
                    ( newModel
                    , sendHttpResponse response
                        (Route.handlers.login.response messageQueue auth.name newModel.world
                            |> Maybe.map Route.handlers.login.encode
                            |> Maybe.withDefault (Route.handlers.login.encodeError NameAndPasswordDoesntCheckOut)
                        )
                    )
                else
                    ( model
                    , sendHttpResponse response (Route.handlers.login.encodeError NameAndPasswordDoesntCheckOut)
                    )
            )
        |> Maybe.withDefault
            ( model
            , sendHttpResponse response (Route.handlers.login.encodeError AuthenticationHeadersMissing)
            )


handleLogout : JE.Value -> Model -> ( Model, Cmd Msg )
handleLogout response model =
    ( model
    , sendHttpResponse response
        (Route.handlers.logout.response model.world
            |> Route.handlers.logout.encode
        )
    )


handleRefresh : Maybe (Auth Hashed) -> JE.Value -> Model -> ( Model, Cmd Msg )
handleRefresh maybeAuth response model =
    maybeAuth
        |> Maybe.map
            (\auth ->
                if Shared.Password.checksOut auth model.world.players then
                    let
                        ( newModel, messageQueue ) =
                            getMessageQueue auth.name model
                    in
                    ( newModel
                    , sendHttpResponse response
                        (Route.handlers.refresh.response messageQueue auth.name newModel.world
                            |> Maybe.map Route.handlers.refresh.encode
                            |> Maybe.withDefault (Route.handlers.refresh.encodeError NameNotFound)
                        )
                    )
                else
                    ( model
                    , sendHttpResponse response (Route.handlers.refresh.encodeError NameAndPasswordDoesntCheckOut)
                    )
            )
        |> Maybe.withDefault
            ( model
            , sendHttpResponse response (Route.handlers.refresh.encodeError AuthenticationHeadersMissing)
            )


handleRefreshAnonymous : JE.Value -> Model -> ( Model, Cmd Msg )
handleRefreshAnonymous response model =
    ( model
    , sendHttpResponse response
        (Route.handlers.refreshAnonymous.response model.world
            |> Route.handlers.refreshAnonymous.encode
        )
    )


handleAttack : Maybe (Auth Hashed) -> String -> JE.Value -> Model -> ( Model, Cmd Msg )
handleAttack maybeAuth them response ({ world } as model) =
    maybeAuth
        |> Maybe.map
            (\auth ->
                let
                    you : String
                    you =
                        auth.name
                in
                if Shared.Password.checksOut auth world.players then
                    if Server.World.isDead you world then
                        handleAttackYouDead you response model
                    else if Server.World.isDead them world then
                        handleAttackThemDead you them response model
                    else
                        handleAttackNobodyDead you them response model
                else
                    ( model
                    , sendHttpResponse response (Route.handlers.attack.encodeError NameAndPasswordDoesntCheckOut)
                    )
            )
        |> Maybe.withDefault
            ( model
            , sendHttpResponse response (Route.handlers.attack.encodeError AuthenticationHeadersMissing)
            )


handleIncSpecialAttr : Maybe (Auth Hashed) -> SpecialAttr -> JE.Value -> Model -> ( Model, Cmd Msg )
handleIncSpecialAttr maybeAuth attr response model =
    maybeAuth
        |> Maybe.map
            (\auth ->
                let
                    maybePlayer : Maybe ServerPlayer
                    maybePlayer =
                        model.world.players
                            |> Dict.get auth.name

                    ( newModel, newMessageQueue ) =
                        maybePlayer
                            |> Maybe.map
                                (\player ->
                                    if player.availableSpecial == 0 then
                                        let
                                            ( newModel_, messageQueue ) =
                                                getMessageQueue auth.name model
                                        in
                                        ( newModel_
                                        , messageQueue ++ [ "You have no SPECIAL points left to redistribute!" ]
                                        )
                                    else
                                        let
                                            modelAfterInc =
                                                updateWorld
                                                    (Server.World.incSpecialAttr attr player.availableSpecial auth.name)
                                                    model

                                            ( newModel_, messageQueue ) =
                                                getMessageQueue auth.name modelAfterInc

                                            message =
                                                if newModel_ == model then
                                                    "You can't add any more points to " ++ Shared.Special.label attr
                                                else
                                                    "You have successfully upgraded your " ++ Shared.Special.label attr
                                        in
                                        ( newModel_
                                        , messageQueue ++ [ message ]
                                        )
                                )
                            |> Maybe.withDefault (getMessageQueue auth.name model)
                in
                ( newModel
                , sendHttpResponse response
                    (Route.handlers.incSpecialAttr.response newMessageQueue auth.name newModel.world
                        |> Maybe.map Route.handlers.incSpecialAttr.encode
                        |> Maybe.withDefault (Route.handlers.incSpecialAttr.encodeError NameNotFound)
                    )
                )
            )
        |> Maybe.withDefault
            ( model
            , sendHttpResponse response
                (Route.handlers.incSpecialAttr.encodeError AuthenticationHeadersMissing)
            )


handleAttackYouDead : String -> JE.Value -> Model -> ( Model, Cmd Msg )
handleAttackYouDead you response model =
    let
        ( modelWithoutMessages, messageQueue ) =
            getMessageQueue you model

        newMessageQueue : List String
        newMessageQueue =
            messageQueue ++ [ "You are dead, you can't fight." ]
    in
    ( modelWithoutMessages
    , sendHttpResponse response
        (Route.handlers.attack.response newMessageQueue you modelWithoutMessages.world Nothing
            |> Maybe.map Route.handlers.attack.encode
            |> Maybe.withDefault (Route.handlers.attack.encodeError NameNotFound)
        )
    )


handleAttackThemDead : String -> String -> JE.Value -> Model -> ( Model, Cmd Msg )
handleAttackThemDead you them response model =
    let
        ( modelWithoutMessages, messageQueue ) =
            getMessageQueue you model

        newMessageQueue : List String
        newMessageQueue =
            messageQueue ++ [ "They are dead already. There's nothing else for you to do." ]
    in
    ( modelWithoutMessages
    , sendHttpResponse response
        (Route.handlers.attack.response newMessageQueue you modelWithoutMessages.world Nothing
            |> Maybe.map Route.handlers.attack.encode
            |> Maybe.withDefault (Route.handlers.attack.encodeError NameNotFound)
        )
    )


handleAttackNobodyDead : String -> String -> JE.Value -> Model -> ( Model, Cmd Msg )
handleAttackNobodyDead you them response model =
    ( model
    , Random.generate
        (\fight -> GeneratedFight ( response, fight ))
        (fightDataGenerator you them model)
    )


type alias FightData =
    { you : String
    , them : String
    , fight : Fight
    }


fightDataGenerator : String -> String -> Model -> Generator (Maybe FightData)
fightDataGenerator yourName theirName model =
    let
        you_ : Maybe ServerPlayer
        you_ =
            Dict.get yourName model.world.players

        them_ : Maybe ServerPlayer
        them_ =
            Dict.get theirName model.world.players
    in
    Maybe.map2
        (\you them ->
            Random.map
                (\fight -> Just (FightData yourName theirName fight))
                (Server.Fight.generator you them)
        )
        you_
        them_
        |> Maybe.withDefault (Random.constant Nothing)


handleAttackWithGeneratedFight : ( JE.Value, Maybe FightData ) -> Model -> ( Model, Cmd Msg )
handleAttackWithGeneratedFight ( response, maybeFightData ) model =
    maybeFightData
        |> Maybe.map
            (\{ you, them, fight } ->
                let
                    worldWithFightLogs : ServerWorld
                    worldWithFightLogs =
                        model.world
                            |> Server.World.addPlayerMessages you
                                (("You attacked " ++ them ++ "!")
                                    :: List.map
                                        (Shared.Fight.eventToString { you = you, them = them })
                                        fight.log
                                )
                            |> Server.World.addPlayerMessages them
                                ((you ++ " attacked you!")
                                    :: List.map
                                        (Shared.Fight.switchPerspective >> Shared.Fight.eventToString { you = them, them = you })
                                        fight.log
                                )

                    newWorld : ServerWorld
                    newWorld =
                        case fight.result of
                            YouWon ->
                                worldWithFightLogs
                                    |> Server.World.setPlayerHp them 0
                                    |> Server.World.addPlayerXp you 10

                            YouLost ->
                                worldWithFightLogs
                                    |> Server.World.setPlayerHp you 0
                                    |> Server.World.addPlayerXp them 5

                    modelAfterFight : Model
                    modelAfterFight =
                        model
                            |> setWorld newWorld

                    ( newModel, messageQueue ) =
                        getMessageQueue you modelAfterFight
                in
                ( newModel
                , sendHttpResponse response
                    (Route.handlers.attack.response messageQueue you newModel.world (Just fight)
                        |> Maybe.map Route.handlers.attack.encode
                        |> Maybe.withDefault (Route.handlers.attack.encodeError NameNotFound)
                    )
                )
            )
        |> Maybe.withDefault
            ( model
            , sendHttpResponse response (Route.handlers.attack.encodeError NameNotFound)
            )


setWorld : ServerWorld -> Model -> Model
setWorld world model =
    { model | world = world }


updateWorld : (ServerWorld -> ServerWorld) -> Model -> Model
updateWorld fn model =
    { model | world = fn model.world }


addPlayer : ServerPlayer -> Model -> Model
addPlayer player model =
    model
        |> updateWorld
            (\world ->
                { world | players = Dict.insert player.name player world.players }
            )


healTickTimeout : Float
healTickTimeout =
    2000


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ httpRequests
            (\value ->
                case JD.decodeValue httpRequestDecoder value of
                    Ok result ->
                        HttpRequest result

                    Err error ->
                        HttpRequestError error
            )
        , Time.every healTickTimeout HealTick
        ]


httpRequestDecoder : Decoder HttpRequestData
httpRequestDecoder =
    JD.map3 HttpRequestData
        (JD.field "url" JD.string)
        (JD.field "response" JD.value)
        (JD.field "headers" (EJ.dictFromObject JD.string))


encodeModel : Model -> JE.Value
encodeModel model =
    JE.object
        [ ( "world", Shared.World.encodeServer model.world )
        ]


modelDecoder : Decoder Model
modelDecoder =
    JD.map Model
        (JD.field "world" Shared.World.serverDecoder)
