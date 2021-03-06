//
//  Decodable.swift
//  Contentful
//
//  Created by JP Wright on 05.09.17.
//  Copyright © 2017 Contentful GmbH. All rights reserved.
//

import Foundation

/**
 Classes conforming to this protocol can be passed into your Client instance so that fetch methods
 asynchronously returning MappedArrayResponse can be used and classes of your own definition can be returned.

 It's important to note that there is no special handling of locales so if using the locale=* query parameter,
 you will need to implement the special handing in your `init(from decoder: Decoder) throws` initializer for your class.

 Example:

 ```
 func fetchMappedEntries(with query: Query<Cat>,
 then completion: @escaping ResultsHandler<MappedArrayResponse<Cat>>) -> URLSessionDataTask?
 ```
 */
public typealias EntryDecodable = Resource & EntryModellable


/// Helper methods for decoding instances of the various types in your content model.
public extension Decoder {

    // The LinkResolver used by the SDK to cache and resolve links.
    internal var linkResolver: LinkResolver {
        return userInfo[.linkResolverContextKey] as! LinkResolver
    }

    internal var contentTypes: [ContentTypeId: EntryDecodable.Type] {
        guard let contentTypes = userInfo[.contentTypesContextKey] as? [ContentTypeId: EntryDecodable.Type] else {
            fatalError(
                """
            Make sure to pass your content types into the `Client` intializer
            so the SDK can properly deserializer your own types if you are using the `fetchMappedEntries` methods
            """)
        }
        return contentTypes
    }

    /// Helper method to extract the sys property of a Contentful resource.
    public func sys() throws -> Sys {
        let container = try self.container(keyedBy: LocalizableResource.CodingKeys.self)
        let sys = try container.decode(Sys.self, forKey: .sys)
        return sys
    }

    /// Extract the nested JSON container for the "fields" dictionary present in Entry and Asset resources.
    public func contentfulFieldsContainer<NestedKey>(keyedBy keyType: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let container = try self.container(keyedBy: LocalizableResource.CodingKeys.self)
        let fieldsContainer = try container.nestedContainer(keyedBy: keyType, forKey: .fields)
        return fieldsContainer
    }
}

internal extension EntryModellable where Self: EntryDecodable {
    // This is a magic workaround for the fact that dynamic metatypes cannot be passed into
    // initializers such as UnkeyedDecodingContainer.decode(Decodable.Type), yet static methods CAN
    // be called on metatypes.
    static func popEntryDecodable(from container: inout UnkeyedDecodingContainer) throws -> Self {
        let entryDecodable = try container.decode(self)
        return entryDecodable
    }
}

internal extension CodingUserInfoKey {
    static let linkResolverContextKey = CodingUserInfoKey(rawValue: "linkResolverContext")!
    static let timeZoneContextKey = CodingUserInfoKey(rawValue: "timeZoneContext")!
    static let contentTypesContextKey = CodingUserInfoKey(rawValue: "contentTypesContext")!
    static let localizationContextKey = CodingUserInfoKey(rawValue: "localizationContext")!
}

extension JSONDecoder {

    /**
     Returns the JSONDecoder owned by the Client. Until the first request to the CDA is made, this
     decoder won't have the necessary localization content required to properly deserialize resources
     returned in the multi-locale format.
     */
    public static func withoutLocalizationContext() -> JSONDecoder {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .custom(Date.variableISO8601Strategy)
        return jsonDecoder
    }

    /**
     Updates the JSONDecoder provided by the client with the localization context necessary to deserialize
     resources returned in the multi-locale format with the locale information provided by the space.
     */
    public func update(with localizationContext: LocalizationContext) {
        userInfo[.localizationContextKey] = localizationContext
    }
}

// Fields JSON container.
public extension KeyedDecodingContainer {

    /**
     Caches a link to be resolved once all resources in the response have been serialized.

     - Parameter key: The KeyedDecodingContainer.Key representing the JSON key were the related resource is found
     - Parameter localeCode: The locale of the link source to be used when caching the relationship for future resolving
     - Parameter decoder: The Decoder being used to deserialize the JSON to a user-defined class
     - Parameter callback: The callback used to assign the linked item at a later time.
     - Throws: Forwards the error if no link object is in the JSON at the specified key.
     */
    public func resolveLink(forKey key: KeyedDecodingContainer.Key,
                            decoder: Decoder,
                            callback: @escaping (Any) -> Void) throws {

        let linkResolver = decoder.linkResolver
        if let link = try decodeIfPresent(Link.self, forKey: key) {
            linkResolver.resolve(link, callback: callback)
        }
    }

    /**
     Caches an array of linked entries to be resolved once all resources in the response have been serialized.

     - Parameter key: The KeyedDecodingContainer.Key representing the JSON key were the related resources arem found
     - Parameter localeCode: The locale of the link source to be used when caching the relationship for future resolving
     - Parameter decoder: The Decoder being used to deserialize the JSON to a user-defined class
     - Parameter callback: The callback used to assign the linked item at a later time.
     - Throws: Forwards the error if no link object is in the JSON at the specified key.
     */
    public func resolveLinksArray(forKey key: KeyedDecodingContainer.Key,
                                  decoder: Decoder,
                                  callback: @escaping (Any) -> Void) throws {

        let linkResolver = decoder.linkResolver
        if let links = try decodeIfPresent(Array<Link>.self, forKey: key) {
            linkResolver.resolve(links, callback: callback)
        }
    }
}

internal class LinkResolver {

    private var dataCache: DataCache = DataCache()

    private var callbacks: [String: [(Any) -> Void]] = [:]

    private static let linksArrayPrefix = "linksArrayPrefix"

    internal func cache(assets: [Asset]) {
        for asset in assets {
            dataCache.add(asset: asset)
        }
    }

    internal func cache(entryDecodables: [EntryDecodable]) {
        for entryDecodable in entryDecodables {
            dataCache.add(entry: entryDecodable)
        }
    }

    // Caches the callback to resolve the relationship represented by a Link at a later time.

    internal func resolve(_ link: Link, callback: @escaping (Any) -> Void) {
        let key = DataCache.cacheKey(for: link)
        if callbacks[key] == nil {
            callbacks[key] = [callback]
        } else {
            callbacks[key]?.append(callback)
        }
    }

    internal func resolve(_ links: [Link], callback: @escaping (Any) -> Void) {
        let linksIdentifier: String = links.reduce(into: LinkResolver.linksArrayPrefix) { (id, link) in
            id += "," + DataCache.cacheKey(for: link)
        }
        if callbacks[linksIdentifier] == nil {
            callbacks[linksIdentifier] = [callback]
        } else {
            callbacks[linksIdentifier]?.append(callback)
        }
    }

    // Executes all cached callbacks to resolve links and then clears the callback cache and the data cache
    // where resources are cached before being resolved.
    internal func churnLinks() {
        for (linkKey, callbacksList) in callbacks {
            if linkKey.hasPrefix(LinkResolver.linksArrayPrefix) {
                let firstKeyIndex = linkKey.index(linkKey.startIndex, offsetBy: LinkResolver.linksArrayPrefix.count)
                let onlyKeysString = linkKey[firstKeyIndex ..< linkKey.endIndex]
                // Split creates a [Substring] array, but we need [String] to index the cache
                let keys = onlyKeysString.split(separator: ",").map { String($0) }
                let items: [Any] = keys.compactMap { dataCache.item(for: $0) }
                for callback in callbacksList {
                    callback(items as Any)
                }
            } else {
                let item = dataCache.item(for: linkKey)
                for callback in callbacksList {
                    callback(item as Any)
                }
            }
        }
        self.callbacks = [:]
        self.dataCache = DataCache()
    }
}


// Inspired by https://gist.github.com/mbuchetics/c9bc6c22033014aa0c550d3b4324411a
internal struct JSONCodingKeys: CodingKey {
    internal var stringValue: String

    internal init?(stringValue: String) {
        self.stringValue = stringValue
    }

    internal var intValue: Int?

    internal init?(intValue: Int) {
        self.init(stringValue: "\(intValue)")
        self.intValue = intValue
    }
}

internal extension KeyedDecodingContainer {

    internal func decode(_ type: Dictionary<String, Any>.Type, forKey key: K) throws -> Dictionary<String, Any> {
        let container = try self.nestedContainer(keyedBy: JSONCodingKeys.self, forKey: key)
        return try container.decode(type)
    }

    internal func decodeIfPresent(_ type: Dictionary<String, Any>.Type, forKey key: K) throws -> Dictionary<String, Any>? {
        guard contains(key) else { return nil }
        guard try decodeNil(forKey: key) == false else { return nil }
        return try decode(type, forKey: key)
    }

    internal func decode(_ type: Array<Any>.Type, forKey key: K) throws -> Array<Any> {
        var container = try self.nestedUnkeyedContainer(forKey: key)
        return try container.decode(type)
    }

    internal func decodeIfPresent(_ type: Array<Any>.Type, forKey key: K) throws -> Array<Any>? {
        guard contains(key) else { return nil }
        guard try decodeNil(forKey: key) == false else { return nil }
        return try decode(type, forKey: key)
    }

    internal func decode(_ type: Dictionary<String, Any>.Type) throws -> Dictionary<String, Any> {
        var dictionary = Dictionary<String, Any>()

        for key in allKeys {
            if let boolValue = try? decode(Bool.self, forKey: key) {
                dictionary[key.stringValue] = boolValue
            } else if let stringValue = try? decode(String.self, forKey: key) {
                dictionary[key.stringValue] = stringValue
            } else if let intValue = try? decode(Int.self, forKey: key) {
                dictionary[key.stringValue] = intValue
            } else if let doubleValue = try? decode(Double.self, forKey: key) {
                dictionary[key.stringValue] = doubleValue
            }
            // Custom contentful types.
            else if let fileMetaData = try? decode(Asset.FileMetadata.self, forKey: key) {
                dictionary[key.stringValue] = fileMetaData
            } else if let link = try? decode(Link.self, forKey: key) {
                dictionary[key.stringValue] = link
            } else if let location = try? decode(Location.self, forKey: key) {
                dictionary[key.stringValue] = location
            }

            // These must be called after attempting to decode all other custom types.
            else if let nestedDictionary = try? decode(Dictionary<String, Any>.self, forKey: key) {
                dictionary[key.stringValue] = nestedDictionary
            } else if let nestedArray = try? decode(Array<Any>.self, forKey: key) {
                dictionary[key.stringValue] = nestedArray
            }
        }
        return dictionary
    }
}

internal extension UnkeyedDecodingContainer {

    internal mutating func decode(_ type: Array<Any>.Type) throws -> Array<Any> {
        var array: [Any] = []
        while isAtEnd == false {
            if try decodeNil() {
                continue
            } else if let value = try? decode(Bool.self) {
                array.append(value)
            } else if let value = try? decode(Int.self) {
                array.append(value)
            } else if let value = try? decode(Double.self) {
                array.append(value)
            } else if let value = try? decode(String.self) {
                array.append(value)
            }
            // Custom contentful types.
            else if let fileMetaData = try? decode(Asset.FileMetadata.self) {
                array.append(fileMetaData) // Custom contentful type.
            } else if let link = try? decode(Link.self) {
                array.append(link) // Custom contentful type.
            }
            // These must be called after attempting to decode all other custom types.
            else if let nestedDictionary = try? decode(Dictionary<String, Any>.self) {
                array.append(nestedDictionary)
            } else if let nestedArray = try? decode(Array<Any>.self) {
                array.append(nestedArray)
            } else if let location = try? decode(Location.self) {
                array.append(location)
            }

        }
        return array
    }

    internal mutating func decode(_ type: Dictionary<String, Any>.Type) throws -> Dictionary<String, Any> {

        let nestedContainer = try self.nestedContainer(keyedBy: JSONCodingKeys.self)
        return try nestedContainer.decode(type)
    }
}
