function [v2_Area, S_parent_Area, S_child_Area, qD_Full_Area,...
    microIterationLosses, itr, ...
    time_dist, R_Area_Matrix, graphDFS_Area, N_Area, busDataTable_pu_Area, ...
    branchDataTable_Area] = ...
    ...
    NL_OPF_dist(v2_parent_Area, S_connection_Area, ...
    Area, isLeaf_Area, isRoot_Area, numChildAreas_Area, numAreas, ...
    microIterationLosses, time_dist, itr, ...
    CB_FullTable, varargin)
    
 % Default values for optional arguments
    verbose = false;
    CVR = [0; 0];
    V_max = 1.05;
    V_min = 0.95;
    Qref_DER = 0.00;
    Vref_DER = 1.00;

    saveToFile = false;
    strArea = convert2doubleDigits(Area);
    fileExtension = ".txt";
    systemName = "ieee123";
    saveLocationName = "logfiles/";
    fileOpenedFlag = false;

    % Process optional arguments
    numArgs = numel(varargin);

    if mod(numArgs, 2) ~= 0
        error('Optional arguments must be specified as name-value pairs.');
    end
    
    validArgs = ["verbose", "systemName", "CVR", "V_max", "V_min", "saveToFile", "saveLocation", "Qref_DER", "Vref_DER"];
    
    for i = 1:2:numArgs
        argName = varargin{i};
        argValue = varargin{i+1};
        
        if ~ischar(argName) || ~any(argName == validArgs)
            error('Invalid optional argument name.');
        end
        
        switch argName
            case "verbose"
                verbose = argValue;
            case "systemName"
                systemName = argValue;
            case "CVR"
                CVR = argValue;
            case "V_max"
                V_max = argValue;
            case "V_min"
                V_min = argValue;
            case 'saveToFile'
                saveToFile = argValue;
            case 'saveLocation'
                saveLocationName = argValue;
            case 'Vref_DER'
                Vref_DER = argValue;
            case 'Qref_DER'
                Qref_DER = argValue;
        end
    end
    
    saveLocationFilename = strcat(saveLocationName , systemName, "/numAreas_", num2str(numAreas), "/Aeq_beq_area", strArea, fileExtension);
    if itr ~= 0 
        verbose = false;
    end

    if verbose && saveToFile && itr == 0 && Area == 2
        fileOpenedFlag = true;
        fid = fopen(saveLocationFilename, 'w');  % Open file for writing
    else
        verbose = false;
        fid = 1;
    end
% ExtractAreaElectricalParameters extracts electrical data required for OPF from an area's csv files. Optionally it can plot the graphs for the areas and save them as pngs.

    [busDataTable_pu_Area, branchDataTable_Area, edgeMatrix_Area, R_Area, X_Area] ...
        = extractAreaElectricalParameters(Area, itr, isRoot_Area, systemName, numAreas, CB_FullTable, numChildAreas_Area);
    
    N_Area = length(busDataTable_pu_Area.bus);
    m_Area = length(branchDataTable_Area.fb);
    fb_Area = branchDataTable_Area.fb;
    tb_Area = branchDataTable_Area.tb;
    P_L_Area = busDataTable_pu_Area.P_L;
    Q_L_Area = busDataTable_pu_Area.Q_L;
    Q_C_Area = busDataTable_pu_Area.Q_C;
    P_der_Area = busDataTable_pu_Area.P_der;
    S_der_Area = busDataTable_pu_Area.S_der;

% Update the Parent Complex Power Vector with values from interconnection. 

    numChildAreas = size(S_connection_Area, 1); %could even be zero for a child-less area
    
    for j = 1:numChildAreas %nodes are numbered such that the last numChildAreas nodes are actually the interconnection nodes too.
        %The load of parent area at the node of interconnection is
        %basically the interconnection area power
        P_L_Area(end-j+1) = real(S_connection_Area(end-j+1));                 %in PU
        Q_L_Area(end-j+1) = imag(S_connection_Area(end-j+1));     
    end
    
    % DER Configuration:
    busesWithDERs_Area = find(S_der_Area); %all nnz element indices
    nDER_Area = length(busesWithDERs_Area);

    mydisp(verbose, ['Number of DERs in Area ', num2str(Area), ' : ', num2str(nDER_Area)]);
    
    S_onlyDERbuses_Area = S_der_Area(busesWithDERs_Area);   %in PU
    P_onlyDERbuses_Area = P_der_Area(busesWithDERs_Area);   %in PU
    lb_Q_onlyDERbuses_Area = -sqrt( S_onlyDERbuses_Area.^2 - P_onlyDERbuses_Area.^2 );
    ub_Q_onlyDERbuses_Area = sqrt( S_onlyDERbuses_Area.^2 - P_onlyDERbuses_Area.^2 );
    
    graphDFS_Area = edgeMatrix_Area; %not doing any DFS
    graphDFS_Area_Table = array2table(graphDFS_Area, 'VariableNames', {'fbus', 'tbus'});

    
    R_Area_Matrix = zeros(N_Area, N_Area);
    X_Area_Matrix = zeros(N_Area, N_Area);
    
    % Matrix form of R and X in terms of graph
    for currentBusNum = 1: N_Area - 1
        R_Area_Matrix(fb_Area(currentBusNum), tb_Area(currentBusNum)) = R_Area(currentBusNum);
        R_Area_Matrix(tb_Area(currentBusNum), fb_Area(currentBusNum)) = R_Area_Matrix(fb_Area(currentBusNum), tb_Area(currentBusNum)) ;
        X_Area_Matrix(fb_Area(currentBusNum), tb_Area(currentBusNum)) = X_Area(currentBusNum);
        X_Area_Matrix(tb_Area(currentBusNum), fb_Area(currentBusNum)) = X_Area_Matrix(fb_Area(currentBusNum), tb_Area(currentBusNum)) ;
    end
% Initializing vectors to be used in the Optimization Problem formulation

    % defining the unknowns for phaseA
    
    numVarsFull = [m_Area, m_Area, m_Area, N_Area, nDER_Area];

    ranges_Full = generateRangesFromValues(numVarsFull);

    indices_P = ranges_Full{1};
    indices_Q = ranges_Full{2};
    indices_l = ranges_Full{3};
    indices_vFull = ranges_Full{4};
    indices_v = indices_vFull(2:end);
    indices_qD = ranges_Full{5};

    Table_Area = [graphDFS_Area_Table.fbus graphDFS_Area_Table.tbus indices_P' indices_Q' indices_l' indices_v'];  % creating Table for variables P, Q ,l, V
    Table_Area_Table = array2table(Table_Area, 'VariableNames', {'fbus', 'tbus', 'indices_P', 'indices_Q', 'indices_l', 'indices_v'});

    % Initialization-
    
     myfprintf(verbose, fid, "**********" + ...
        "Constructing Aeq and beq for Area %d.\n" + ...
        "***********\n", Area);

    CVR_P = CVR(1);
    CVR_Q = CVR(2);
    
    numLinOptEquations = 3*m_Area + 1;
    numOptVarsFull = 3*m_Area + N_Area + nDER_Area;
    Aeq = zeros(numLinOptEquations, numOptVarsFull);
    beq = zeros(numLinOptEquations, 1);

    for currentBusNum = 2 : N_Area
        myfprintf(verbose, fid, "*****\n" + ...
            "Checking for bus %d.\n" + ...
            "*****\n", currentBusNum);       
 
        % The row index showing the 'parent' bus of our currentBus:
        
        parentBusIdx = find(graphDFS_Area_Table.tbus == currentBusNum);
        parentBusNum = graphDFS_Area_Table.fbus(parentBusIdx);
        myfprintf(verbose, fid, "The parent of bus %d is bus %d at index %d.\n", currentBusNum, parentBusNum, parentBusIdx);

        % Aeq = zeros( 3*(N_Area-1), Table_Area_Table{end, end} ); %zeros(120, 121)
        % beq = zeros( 3*(N_Area-1), 1); %zeros(120, 1)
        % Aeq formulations
        %P equations
    %     busesWithDERs_Area
        PIdx = parentBusIdx;
        Aeq( PIdx, indices_P(parentBusIdx) ) = 1;
        Aeq( PIdx, indices_l(parentBusIdx) ) = -R_Area_Matrix( parentBusNum, currentBusNum );
        Aeq( PIdx, indices_v(parentBusIdx) ) = -0.5 * CVR_P * P_L_Area( currentBusNum );

        
        %Q equations
        QIdx = PIdx + (N_Area-1);
        Aeq( QIdx, indices_Q(parentBusIdx) ) = 1;
        % myfprintf(verbose, fid, "Note that we've used QIdx = %d, instead of %d for indexing into Aeq.\n", QIdx, indices_Q(parentBusIdx));
        Aeq( QIdx, indices_l(parentBusIdx) ) = -X_Area_Matrix( parentBusNum, currentBusNum );
        Aeq( QIdx, indices_v(parentBusIdx) ) = -0.5 * CVR_Q * Q_L_Area( currentBusNum );

        
       % List of Row Indices showing the set of 'children' buses 'under' our currentBus:
        childBusIndices = find(graphDFS_Area_Table.fbus == currentBusNum);
        % childBuses = graphDFS_Area_Table.tbus(childBusIndices);
        if isempty(childBusIndices)
            % myfprintf(verbose, fid, "It is a leaf node.\n");
        else
            % myfprintf(verbose, fid, "The child buses of bus %d\n", currentBusNum);
            % myfprintf(verbose, fid, "include: buses %d\n", childBuses);
            % myfprintf(verbose, fid, "at indices %d.\n", childBusIndices);
            Aeq(PIdx, indices_P(childBusIndices) ) = -1;   % for P
            Aeq(QIdx, indices_Q(childBusIndices) ) = -1;   % for Q
        end
        
        myfprintf(verbose, fid, "Aeq(%d, P(%d)) = 1.\n", PIdx, parentBusIdx);
        myfprintf(verbose, fid, "Aeq(%d, l(%d)) = -r(%d, %d).\n", PIdx, parentBusIdx, parentBusNum, currentBusNum);
        for i = 1:length(childBusIndices)
            myfprintf(verbose, fid, "Aeq(%d, P(%d)) = -1\n", PIdx, childBusIndices(i));
        end
        if CVR_P
            myfprintf(verbose, fid, "Aeq(%d, v(%d)) = -0.5 * CVR_P * P_L(%d).\n", PIdx, parentBusIdx, currentBusNum);
        end
        

        myfprintf(verbose, fid, "Aeq(%d, Q(%d)) = 1.\n", QIdx, parentBusIdx);
        myfprintf(verbose, fid, "Aeq(%d, l(%d)) = -x(%d, %d).\n", QIdx, parentBusIdx, parentBusNum, currentBusNum);
        for i = 1:length(childBusIndices)
            myfprintf(verbose, fid, "Aeq(%d, Q(%d)) = -1\n", QIdx, childBusIndices(i));
        end
        if CVR_Q
            myfprintf(verbose, fid, "Aeq(%d, v(%d)) = -0.5 * CVR_Q * Q_L(%d).\n", QIdx, parentBusIdx, currentBusNum);
        end

        % V equations
        % vIdx = parentBusIdx + 2*(N_Area-1);
        vIdx = QIdx + (N_Area-1);
        Aeq( vIdx, indices_v(parentBusIdx) ) = 1;
        myfprintf(verbose, fid, "Aeq(%d, v(%d)) = 1\n", vIdx, parentBusIdx);

        %Return the rows with the list of 'children' buses of 'under' the PARENT of our currentBus:
        %our currentBus will obviously also be included in the list.
        siblingBusesIndices = find(graphDFS_Area_Table.fbus == parentBusNum);
        siblingBuses = graphDFS_Area_Table.tbus(siblingBusesIndices);

        myfprintf(verbose, fid, "The siblings of bus %d\n", currentBusNum);
        myfprintf(verbose, fid, "include these buses: %d\n", siblingBuses)
        myfprintf(verbose, fid, "at indices %d.\n", siblingBusesIndices);
        eldestSiblingIdx = siblingBusesIndices(1);
        eldestSiblingBus = siblingBuses(1);
        myfprintf(verbose, fid,  "which makes bus %d at index %d as the eldest sibling.\n", eldestSiblingBus, eldestSiblingIdx);
        Aeq( vIdx, indices_vFull( eldestSiblingIdx ) ) = -1;
        myfprintf(verbose, fid, "Aeq(%d, v_Full(%d)) = -1\n", vIdx, eldestSiblingIdx);
        Aeq( vIdx, indices_P(parentBusIdx) ) = 2 * R_Area_Matrix( parentBusNum, currentBusNum );
        myfprintf(verbose, fid, "Aeq(%d, P(%d)) = 2*r(%d, %d).\n", vIdx, parentBusIdx, parentBusNum, currentBusNum);
        Aeq( vIdx, indices_Q(parentBusIdx) ) = 2 * X_Area_Matrix( parentBusNum, currentBusNum );
        myfprintf(verbose, fid, "Aeq(%d, Q(%d)) = 2*x(%d, %d).\n", vIdx, parentBusIdx, parentBusNum, currentBusNum);
        Aeq( vIdx, indices_l(parentBusIdx) ) = ...
            -R_Area_Matrix( parentBusNum, currentBusNum )^2 + ...
            -X_Area_Matrix( parentBusNum, currentBusNum )^2 ;
        myfprintf(verbose, fid, "Aeq(%d, l(%d)) = -r(%d, %d)^2 -x(%d, %d)^2.\n", vIdx, parentBusIdx, parentBusNum, currentBusNum, parentBusNum, currentBusNum);
        
        % beq Formulation
    %     beq = zeros(1, 3*N_Area - 2);
        beq( PIdx ) = ...
            ( 1- 0.5 * CVR_P ) * ...
            ( P_L_Area( currentBusNum ) - P_der_Area( currentBusNum ) );
        myfprintf(verbose, fid, "beq(%d) = (1 - 0.5*CVR_P)*(P_L(%d) - P_der(%d))\n", PIdx, currentBusNum, currentBusNum);
    
        beq( QIdx ) =  ...
            ( 1- 0.5*CVR_Q ) * ...
            ( Q_L_Area( currentBusNum ) - Q_C_Area( currentBusNum ) );
        myfprintf(verbose, fid, "beq(%d) = (1 - 0.5*CVR_Q)*(Q_L(%d) - Q_C(%d))\n", QIdx, currentBusNum, currentBusNum);

    end
    
    % substation voltage equation
    vSubIdx = 3*m_Area + 1;
    Aeq( vSubIdx, indices_vFull(1) ) = 1;
    myfprintf(verbose, fid, "Aeq(%d, v_Full(1)) = 1\n", vSubIdx);

    beq(vSubIdx) = v2_parent_Area;
    myfprintf(verbose, fid, "beq(%d) = %.3f\n", vSubIdx, v2_parent_Area);
    
    % DER equation addition
    Table_DER = zeros(nDER_Area, 5);
    
    for i = 1:nDER_Area
        currentBusNum = busesWithDERs_Area(i);
        parentBusIdx = find(graphDFS_Area_Table.tbus == currentBusNum);
        QIdx = parentBusIdx + m_Area;
        qD_Idx = indices_qD(i);
        Aeq(QIdx, qD_Idx) = 1;
        myfprintf(verbose, fid, "Aeq(%d, qD(%d)) = 1\n", QIdx, i);
        
        %setting other parameters for DGs:
        Table_DER(i, 2) = qD_Idx;
        
        % slope kq definiton:
        Table_DER(i, 3) = 2*ub_Q_onlyDERbuses_Area(i)/(V_max-V_min); % Qmax at Vmin, and vice versa
        
        % Q_ref, V_ref definition:
        Table_DER(i, 4) = Qref_DER;  %Qref
        Table_DER(i, 5) = Vref_DER;  %Vref
    end
    
    % Table_DER_Table = array2table(Table_DER, 'VariableNames', {'Idx', 'DG_parameter', 'Slope_kq', 'Q_ref', 'V_ref'});
    % mydisplay(verbose, Table_DER_Table)
    
    if fileOpenedFlag
        fclose(fid);
    end
    
    % calling linear solution for intial point
    x_linear_Area = ...
        singlephaselin(busDataTable_pu_Area, branchDataTable_Area, v2_parent_Area, S_connection_Area, isLeaf_Area, ...
        Area, numAreas, graphDFS_Area, graphDFS_Area_Table, R_Area_Matrix, X_Area_Matrix, ...
        lb_Q_onlyDERbuses_Area, ub_Q_onlyDERbuses_Area, itr, 'verbose', true);

    numVarsNoLoss = [m_Area, m_Area, N_Area, nDER_Area];
    ranges_noLoss = generateRangesFromValues(numVarsNoLoss);

    indices_P_noLoss = ranges_noLoss{1};
    indices_Q_noLoss = ranges_noLoss{2};
    indices_vFull_noLoss = ranges_noLoss{3};
    indices_qD_noLoss = ranges_noLoss{4};

    P0_Area = x_linear_Area( indices_P_noLoss );
    Q0_Area = x_linear_Area( indices_Q_noLoss );
    v0_Area =  x_linear_Area( indices_vFull_noLoss );
    qD0_Area = x_linear_Area( indices_qD_noLoss );
    
    Iflow0 = zeros(m_Area, 1);
    for currentBusNum = 2 : N_Area
        parentBusIdx = find(graphDFS_Area_Table.tbus == currentBusNum);
        siblingBusesIndices = find(parentBusNum == graphDFS_Area_Table.fbus);
        Iflow0( parentBusIdx ) = ( P0_Area(parentBusIdx)^2 + Q0_Area(parentBusIdx)^2 ) / v0_Area(siblingBusesIndices(1));
    end
    
    x0_Area = [P0_Area; Q0_Area; Iflow0; v0_Area; qD0_Area];
    
    % Definig Limits
    
    numVarsForBoundsFull = [1, numVarsFull(1) - 1, numVarsFull(2:end-1) ]; % qD limits are specific to each machine, will be appended later.
    lbVals = [0, -1500, -1500, 0, V_min^2];
    ubVals = [1500, 1500, 1500, 1500, V_max^2];
    [lb_Area, ub_Area] = constructBoundVectors(numVarsForBoundsFull, lbVals, ubVals);
    
    lb_AreaFull = [lb_Area; lb_Q_onlyDERbuses_Area];
    ub_AreaFull = [ub_Area; ub_Q_onlyDERbuses_Area];
    
    if itr == 0 && Area == 2
        mydisplay(verbose, "branchTable",  graphDFS_Area_Table)
        mydisplay(verbose, "Aeq", Aeq)
        mydisplay(verbose, "beq", beq)
        mydisplay(verbose, "lb", lb_AreaFull)
        mydisplay(verbose, "ub", ub_AreaFull)
    end

    %  Optimization - 
    options = optimoptions('fmincon', 'Display', 'off', 'MaxFunctionEvaluations', 100000000, 'Algorithm', 'sqp');
    
    startSolvingForOptimization = tic;

    [x, ~, ~, ~] = fmincon( @(x)objfunTables(x, N_Area, graphDFS_Area_Table.fbus, graphDFS_Area_Table.tbus, indices_l, R_Area_Matrix), ...
                              x0_Area, [], [], Aeq, beq, lb_AreaFull, ub_AreaFull, ...
                              @(x)eqcons(x, Area, N_Area, ...
                              graphDFS_Area_Table.fbus, graphDFS_Area_Table.tbus, indices_P, indices_Q, indices_l, indices_vFull, ...
                              itr, systemName, numAreas, "verbose", false, "saveToFile", false),...
                              options);
    
    optimizationSolutionTime = toc(startSolvingForOptimization);
    
    time_dist(itr+1, Area) = optimizationSolutionTime;
    
    % Result
    Pall = x(indices_P); %40x1
    Qall = x(indices_Q); %40x1
    Sall = complex(Pall, Qall); %40x1
    P1 = Pall(1); %1x1
    Q1 = Qall(1); %1x1
    S_parent_Area = complex(P1, Q1);  %1x1  % In Pu

    
    qD_Area = x(indices_qD);

    qD_Full_Area = zeros(N_Area, 1);

    for i = 1 : nDER_Area
        qD_Full_Area( busesWithDERs_Area(i) ) = qD_Area(i);
    end
       
    v2_Area = zeros(N_Area, 1);
    S_child_Area = zeros(N_Area, 1);

    for j = 1:size(Table_Area,1)
        v2_Area( Table_Area_Table.tbus(j) ) = x( end - N_Area + 1 - nDER_Area + j);
        S_child_Area( Table_Area_Table.tbus(j) - 1 ) = Sall(j);
    end
    
    v2_Area(1) = v2_parent_Area;
    
    microIterationLosses(itr + 1, Area) = P1 + sum(P_der_Area) - sum(P_L_Area);

end