//
//  Copyright (c) 2018. Uber Technologies
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import SourceKittenFramework

func renderMocks(inheritanceMap: [String: (Structure, File, [Model])],
                 annotatedProtocolMap: [String: ProtocolMapEntryType],
                 semaphore: DispatchSemaphore?,
                 queue: DispatchQueue?,
                 process: @escaping (Structure, File, String) -> ()) -> Bool {
    
    if let queue = queue {
        let lock = NSLock()
        
        for key in annotatedProtocolMap.keys {
            _ = semaphore?.wait(timeout: DispatchTime.distantFuture)
            queue.async {
                _ = renderMocksForClass(inheritanceMap: inheritanceMap, key: key, annotatedProtocolMap: annotatedProtocolMap, lock: lock, process: process)
                semaphore?.signal()
            }
        }
        queue.sync(flags: .barrier) { }
    } else {
        for key in annotatedProtocolMap.keys {
            _ = renderMocksForClass(inheritanceMap: inheritanceMap, key: key, annotatedProtocolMap: annotatedProtocolMap, lock: nil, process: process)
        }
    }
    return false
}

private func renderMocksForClass(inheritanceMap: [String: (Structure, File, [Model])],
                                 key: String,
                                 annotatedProtocolMap: [String: ProtocolMapEntryType],
                                 lock: NSLock? = nil,
                                 process: @escaping (Structure, File, String) -> ()) -> Bool {
    if let val = annotatedProtocolMap[key] {
        let protocolStructure = val.structure
        let file = val.file
        
        let (models, attributes, processedResults) = lookupEntities(name: key, inheritanceMap: inheritanceMap, annotatedProtocolMap: annotatedProtocolMap)
        
        let uniqueVals = uniqueEntities(in: models).sorted { $0.value.offset < $1.value.offset }
        let renderedEntities = uniqueVals.compactMap { (name: String, model: Model) -> String? in
            return model.render(with: name)
        }

        let nonOptionalOrRxVarList = nonOptionalOrRxVars(in: models)

        let mockModel = ClassModel(protocolStructure,
                                   content: file.contents,
                                   identifier: key,
                                   additionalAttributes: attributes,
                                   initParams: nonOptionalOrRxVarList,
                                   entities: [processedResults.joined(), renderedEntities.joined(separator: "\n")])
        if let mockString = mockModel.render(with: key), !mockString.isEmpty {
            lock?.lock()
            process(protocolStructure, file, mockString)
            lock?.unlock()
        }
    }
    return false
}

private func uniqueEntities(`in` models: [Model]) -> [String: Model] {
    let entities = Dictionary(grouping: models) { $0.name }
    var result = [String: Model]()
    
    entities.forEach { (key: String, value: [Model]) in
        if value.count > 1 {
            let entitiesByMediumName = Dictionary(grouping: value) { $0.mediumName }
            entitiesByMediumName.forEach { (k: String, v: [Model]) in
                if v.count > 1 {
                    let entitiesByLongName = Dictionary(grouping: value) { $0.longName }
                    entitiesByLongName.forEach { (k: String, v: [Model]) in
                        if v.count > 1 {
                            v.forEach{ result[$0.fullName] = $0 }
                        } else {
                            v.forEach{ result[$0.longName] = $0 }
                        }
                    }
                } else {
                    v.forEach { result[$0.mediumName] = $0 }
                }
            }
        } else {
            value.forEach { result[$0.name] = $0 }
        }
    }
    
    return result
}

private func nonOptionalOrRxVars(`in` models: [Model]) -> [VariableModel] {
    let paramsForInit = models.compactMap {$0 as? VariableModel}.filter { $0.canBeInitParam }
    let parentVars = paramsForInit.filter {$0.processed}.sorted { $0.offset < $1.offset }
    let parentVarNames = parentVars.map {$0.name}
    // Named params in init should be unique. Add a duplicate param check to ensure it.
    let curVars = paramsForInit.filter { !$0.processed && !parentVarNames.contains($0.name) }
                                .sorted {$0.offset < $1.offset}
    let result = [parentVars, curVars].flatMap{$0}
    return result
}
