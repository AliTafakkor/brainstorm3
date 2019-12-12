function [res, filteredComment] = node_apply_search(iSearch, fileType, fileComment, fileName)
% NODE_APPLY_SEARCH: Apply a search structure to one or more file (node) in the database tree
%
% USAGE:  [res, filteredComment] = node_apply_search(iSearch, fileType, fileComment, fileName)
%
% INPUT: 
%    - iSearch: ID of the search to apply, or root of a search structure
%    - fileType: Type of the file(s)
%    - fileComment: Comment (name) of the file(s)
%    - fileName: Path of the file(s)
%
% OUTPUT: 
%    - res: Whether the file(s) pass the search (1) or not (0)
%    - filteredComment: Comment (name) of the file to display on the search
%                       tab (this allows us to bold searched keywords)

% @=============================================================================
% This function is part of the Brainstorm software:
% https://neuroimage.usc.edu/brainstorm
% 
% Copyright (c)2000-2019 University of Southern California & McGill University
% This software is distributed under the terms of the GNU General Public License
% as published by the Free Software Foundation. Further details on the GPLv3
% license can be found at http://www.gnu.org/copyleft/gpl.html.
% 
% FOR RESEARCH PURPOSES ONLY. THE SOFTWARE IS PROVIDED "AS IS," AND THE
% UNIVERSITY OF SOUTHERN CALIFORNIA AND ITS COLLABORATORS DO NOT MAKE ANY
% WARRANTY, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF
% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, NOR DO THEY ASSUME ANY
% LIABILITY OR RESPONSIBILITY FOR THE USE OF THIS SOFTWARE.
%
% For more information type "brainstorm license" at command prompt.
% =============================================================================@
%
% Authors: Martin Cousineau, 2019

filteredComment = fileComment;

if isnumeric(iSearch)
    % If no filter applied, the file passes by default
    if iSearch == 0
        if iscell(fileName)
            res = true(1, length(fileName));
        else
            res = 1;
        end
        return;
    end
    % Get the active search
    searchRoot = panel_protocols('ActiveSearch', 'get', iSearch);
    if isempty(searchRoot)
        error(sprintf('Could not find active search #%d', iSearch));
    end
else
    % Search structure provided in arguments
    searchRoot = iSearch;
end

% Apply the search nodes recursively
[res, boldKeywords] = TestSearchTree(searchRoot, fileType, fileComment, fileName);

% Bold contained keywords in node comment
if nargout > 1 && ~isempty(boldKeywords)
    for iKeyword = 1:length(boldKeywords)
        filteredComment = strAddKeywordDelimiter(filteredComment, boldKeywords{iKeyword}, '<B>', '</B>');
    end
    filteredComment = ['<HTML>' filteredComment];
end
end

% Function that goes through child search nodes recursively
%
% Usage: see top of this file
function [res, boldKeywords] = TestSearchTree(root, fileType, fileComment, fileName)
    if iscell(fileName)
        res = true(1, length(fileName));
    else
        res = 1;
    end
    nextBool = 0;
    nextNot = 0;
    nChildren = length(root.Children);
    boldKeywords = {};
    
    % Apply each child of search structure
    for iChild = 1:nChildren
        switch root.Children(iChild).Type
            case 1 % Search param
                param = root.Children(iChild).Value;
                [curRes, boldKeyword] = TestParam(param, fileType, fileComment, fileName);
                % Save comment 
                if any(curRes) && ~isempty(boldKeyword)
                    boldKeywords{end + 1} = boldKeyword;
                end
            case 2 % Boolean
                if root.Children(iChild).Value == 3 % NOT
                    nextNot = 1;
                else
                    nextBool = root.Children(iChild).Value;
                end
                curRes = [];
            case 3 % Nested block, apply test recursively
                [curRes, boldKeywords2] = TestSearchTree(root.Children(iChild), fileType, fileComment, fileName);
                boldKeywords = [boldKeywords, boldKeywords2];
            otherwise
                error('Invalid node type.');
        end
        
        % Combine child results using previously found boolean operator
        if ~isempty(curRes)
            % Apply NOT
            if nextNot
                curRes = ~curRes;
                nextNot = 0;
            end
            switch nextBool
                case 1 % AND
                    res = res & curRes;
                case 2 % OR
                    res = res | curRes;
                otherwise
                    res = curRes;
            end
        end
            
    end
end

% Tests a database file using a db_template('searchparam') structure
function [matches, boldKeyword] = TestParam(param, fileType, fileComment, fileName)
    boldKeyword = [];
    % Choose value to search for
    if param.SearchType == 1
        % Comment
        fileValue = fileComment;
    elseif param.SearchType == 2
        % Type
        fileValue = fileType;
    elseif param.SearchType == 3
        % File name
        fileValue = fileName;
    else
        error('Unsupported search type');
    end
    
    % Apply case sensitivity
    searchValue = param.Value;
    if ~param.CaseSensitive
        fileValue = lower(fileValue);
        searchValue = lower(searchValue);
    end
    
    % Detect if we're testing multiple files at once
    if iscell(fileComment)
        nTotalFiles = length(fileComment);
    else
        nTotalFiles = 1;
    end
    if iscell(fileValue)
        nFiles = nTotalFiles;
        matches = true(1, nFiles);
    else
        fileValue = {fileValue};
        nFiles = 1;
        matches = 1;
    end
    
    for iFile = 1:nFiles
        % Test for equality
        if param.EqualityType == 1
            % Contains
            allMatches = strfind(fileValue{iFile}, searchValue);
            matches(iFile) = ~isempty(allMatches);
            % Add bold tags to search keyword(s)
            if matches(iFile)
                boldKeyword = searchValue;
            end
        elseif param.EqualityType == 2
            % Equals
            matches(iFile) = any(strcmp(fileValue{iFile}, searchValue));
        else
            error('Unsupported equality type');
        end
    end
    
    % Propagate to all files
    if nFiles == 1 && nTotalFiles > nFiles
        matches = repmat(matches, 1, nTotalFiles);
    end
end

% Adds left and right delimiters around 'keyword' in string 'allStr' while
% keeping original case of keyword
% Example: strAddKeywordDelimiter('This the', 'th', '<B>', '</B>')
%    = '<B>Th</B>is <B>th</B>e'
function outStr = strAddKeywordDelimiter(allStr, keyword, delL, delR)
    % Repeat left delimiter if right delimiter not specified
    if nargin < 4
        delR = delL;
    end
    % Support calls from both a single string and cell array of string
    isSingle = ~iscell(allStr);
    if isSingle
        allStr = {allStr};
    end
    nStrings = length(allStr);
    outStr = cell(1, nStrings);
    
    keywordLen = length(keyword);
    for iStr = 1:nStrings
        str = allStr{iStr};
        stringLen = length(str);
        iPosKeywords = strfind(lower(str), lower(keyword));
        out = [];
        iPos = 1;
        % Loop through keywords
        for iKeyword = 1:length(iPosKeywords)
            iPosKeyword = iPosKeywords(iKeyword);
            % Add portion of string before keyword
            if iPosKeyword > iPos
                out = [out str(iPos:iPosKeyword-1)];
            end
            % Add keyword + delimiters
            iPos = iPosKeyword + keywordLen;
            out = [out delL str(iPosKeyword:iPos - 1) delR];
        end
        % Add portion of string after keywords
        if iPos <= stringLen
            out = [out str(iPos:stringLen)];
        end
        outStr{iStr} = out;
    end
    
    if isSingle
        outStr = outStr{1};
    end
end
