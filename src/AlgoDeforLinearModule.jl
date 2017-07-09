"""
    AlgoDeforLinearModule

Module for algorithms used in linear deformation models.
"""
module AlgoDeforLinearModule

using FinEtools
using FinEtools.AlgoBaseModule.dcheck!

"""
    AlgoDeforLinearModule.linearstatics(modeldata::FDataDict)

Algorithm for static linear deformation (stress) analysis.

`modeldata` = dictionary with values for keys

- "fens"  = finite element node set
- "regions"  = array of region dictionaries
- "essential_bcs" = array of essential boundary condition dictionaries
- "traction_bcs" = array of traction boundary condition dictionaries
- "temperature_change" = dictionary of data for temperature change

For each region (connected piece of the domain made of a particular material),
mandatory, the  region dictionary  contains values for keys:
- "femm" = finite element mmodel machine (mandatory);

For essential boundary conditions (optional) each dictionary
would hold
  + "displacement" = fixed (prescribed) displacement (scalar),  or
            a function with signature
                function w = f(x)
            If not given, zero displacement assumed.
  + "component" = which component is prescribed  (1, 2, 3)?
  + "node_list" = list of nodes on the boundary to which the condition applies
            (mandatory)

For traction boundary conditions (optional) each dictionary
would hold
  + "femm" = finite element mmodel machine (mandatory);
  + "traction_vector" = traction vector,  either  a constant or  a function
        Positive  when outgoing.

Output:
modeldata= the dictionary on input is augmented with
- "geom" = the nodal field that is the geometry
- "u" = the nodal field that is the computed displacement
"""
function linearstatics(modeldata::FDataDict)

  # For traction boundary conditions (optional):
  # model_data.boundary_conditions.traction = cell array of struct,
  #           each piece of surface with traction boundary condition gets one
  #           element of the array with a struct with the attributes
  #     traction=traction (vector), supply a zero for component in which
  #           the boundary condition is inactive
  #     fes = finite element set on the boundary to which
  #                       the condition applies
  #     integration_rule= integration rule
  #
  # For body loads (optional):
  # model_data.body_load = cell array of struct,
  #          each piece of the domain can have each its own body load
  #     force  = force density vector
  #     fes = finite element set to which the load applies
  #     integration_rule= integration rule
  #
  # For multi point constraints (MPC) (optional):
  # model_data.mpc= cell array of structs, each for one MPC.
  #      node_list = list of node numbers involved in the MPC,
  #      dof_list= numbers of degrees of freedom for the nodes above,
  #      umultipliers=multipliers for the nodes above,
  #      penfact=the penalty factor to multiply  the constraint matrix,
  #          The MPC looks like this: sum_i m_i u_{dof(i),node(i)} =0
  #          where m_i is the multiplier.

  # Lists of recognized keys for the data dictionaries:
  modeldata_recognized_keys = ["fens", "regions",
  "essential_bcs",  "traction_bcs", "temperature_change",
  "factorize"]
  essential_bcs_recognized_keys = ["displacement", "node_list", "component"]
  traction_bcs_recognized_keys = ["femm", "traction_vector"]
  regions_recognized_keys = ["femm", "body_load"]
  temperature_change_recognized_keys = ["temperature"]

  # Extract the nodes
  fens=get(()->error("Must get fens!"), modeldata, "fens")

  # Construct the geometry field
  geom = NodalField(fens.xyz)

  # Construct the displacement field
  u = NodalField(zeros(nnodes(geom), ndofs(geom)))

  # Apply the essential boundary conditions on the displacement field
  essential_bcs = get(modeldata, "essential_bcs", nothing);
  if (essential_bcs != nothing)
    for j = 1:length(essential_bcs)
      ebc = essential_bcs[j]
      dcheck!(ebc, essential_bcs_recognized_keys)
      fenids = get(()->error("Must get node list!"), ebc, "node_list");
      displacement = get(ebc, "displacement", nothing);
      u_fixed = zeros(FFlt, length(fenids)); # default is  zero displacement
      if (displacement != nothing) # if it is nonzero,
        if (typeof(displacement) <: Function) # it could be a function
          for k = 1:length(fenids)
            u_fixed[k] = displacement(geom.values[fenids[k],:])[1];
          end
        else # or it could be a constant
          fill!(u_fixed, displacement);
        end
      end
      component = get(ebc, "component", 0); # which component?
      setebc!(u, fenids[:], true, component, u_fixed);
    end
    applyebc!(u);
  end

  # Number the equations
  numberdofs!(u)           #,Renumbering_options); # NOT DONE <<<<<<<<<<<<<<<<<

  # Initialize the heat loads vector
  F = zeros(FFlt,u.nfreedofs);

  # Construct the system stiffness matrix
  K = spzeros(u.nfreedofs,u.nfreedofs); # (all zeros, for the moment)
  regions = get(()->error("Must get region list!"), modeldata, "regions")
  for i = 1:length(regions)
    region = regions[i]
    dcheck!(region, regions_recognized_keys)
    femm = region["femm"];
    # # Give the  FEMM a chance  to precompute  geometry-related quantities
    femm = associategeometry!(femm, geom);
    # Add up all the conductivity matrices for all the regions
    K = K + stiffness(femm, geom, u);
    # Loads due to the essential boundary conditions on the displacement field
    essential_bcs = get(modeldata, "essential_bcs", nothing);
    if (essential_bcs != nothing) # there was at least one EBC applied
      F = F + nzebcloadsstiffness(femm, geom, u);
    end
  end

  # # Process the body load
  # body_load = get(modeldata, "body_load", nothing);
  # if (body_load  !=nothing)
  #     for j=1:length(model_data.body_load)
  #         body_load =model_data.body_load{j};
  #         femm = femm_deformation_linear (struct ('material',[],...
  #             'fes',body_load.fes,...
  #             'integration_rule',body_load.integration_rule));
  #         fi= force_intensity(struct('magn',body_load.force));
  #         F = F + distrib_loads(femm, sysvec_assembler, geom, u, fi, 3);
  #     end
  #     clear body_load fi  femm
  # end

  # Process the traction boundary condition
  traction_bcs = get(modeldata, "traction_bcs", nothing);
  if (traction_bcs != nothing)
    for j=1:length(traction_bcs)
      tractionbc = traction_bcs[j]
      dcheck!(tractionbc, traction_bcs_recognized_keys)
      traction_vector = tractionbc["traction_vector"];
      if (typeof(traction_vector) <: Function)
        fi = ForceIntensity(FFlt, ndofs(geom), traction_vector);
      else
        fi = ForceIntensity(traction_vector);
      end
      femm = tractionbc["femm"]
      F = F + distribloads(femm, geom, u, fi, 2);
    end
  end

  # Process the thermal strain  loading
  temperature_change = get(modeldata, "temperature_change", nothing);
  if (temperature_change != nothing)
    dcheck!(temperature_change, temperature_change_recognized_keys)
    # zero temperature change is a reasonable default
    temp = NodalField(zeros(size(fens.xyz,1),1))
    temperature = get(temperature_change, "temperature", nothing);
    if (temperature != nothing) # if it is nonzero,
      if (typeof(temperature) <: Function) # it could be a function
        for k = 1:count(fens)
          temp.values[k] = temperature(geom.values[k,:])[1];
        end
      else # or it could be a constant
        fill!(temp.values, temperature);
      end
    end
    for i = 1:length(regions)
      region = regions[i]
      femm = region["femm"];
      F = F + thermalstrainloads(femm, geom, u, temp)
    end
  end

  # # Process the nodal force boundary condition
  # if (isfield(model_data.boundary_conditions, 'nodal_force' ))
  #     for j=1:length(model_data.boundary_conditions.nodal_force)
  #         nodal_force =model_data.boundary_conditions.nodal_force{j};
  #         femm = femm_deformation_linear (struct ('material',[],...
  #             'fes',fe_set_P1(struct('conn',reshape(nodal_force.node_list,[],1))),...
  #             'integration_rule',point_rule));
  #         fi= force_intensity(struct('magn',nodal_force.force));
  #         F = F + distrib_loads(femm, sysvec_assembler, geom, u, fi, 0);
  #     end
  #     clear nodal_force fi femm
  # end

  # # Apply multi point constraints
  # if isfield(model_data,'mpc')
  #     for i=1:length(model_data.mpc)
  #         mpc =model_data.mpc{i};
  #         dofnums=0*mpc.umultipliers;# Construct an array of the degree of freedom numbers
  #         for kx=1:length(mpc.node_list)
  #             dofnums(kx)=u.dofnums(mpc.node_list(kx),mpc.dof_list(kx));
  #         end
  #         # Now call the utility function to calculate the constraint matrix
  #         [Kmpc,Fmpc]=apply_penalty_mpc(u.nfreedofs,dofnums,mpc.umultipliers,0.0,mpc.penfact);
  #         K = K + Kmpc;
  #         F = F + Fmpc;
  #     end
  #     clear Kmpc Fmpc
  # end

  # Solve the system of linear algebraic equations
  K = cholfact(K);
  U = K\F;
  scattersysvec!(u, U[:])


  # Update the model data
  setindex!(modeldata, geom, "geom");
  setindex!(modeldata, u, "u");
  setindex!(modeldata, dot(F,U)/2, "work");
  return modeldata            # ... And return the updated model data
end

"""
    AlgoDeforLinearModule.exportdeformation(modeldata::FDataDict)

Algorithm for exporting of the deformation for visualization in Paraview.

`modeldata` = dictionary with values for keys

- "fens"  = finite element node set
- "regions"  = array of region dictionaries
- "geom" = geometry field
- "u" = displacement field
- "postprocessing" = dictionary  with values for keys
  + "boundary_only" = should only the boundary of the  regions be rendered?
                      Default is render the interior.
  + "file" = name of the  postprocessing file

For each region (connected piece of the domain made of a particular material),
mandatory, the  region dictionary  contains values for keys:
- "femm" = finite element mmodel machine (mandatory);

Output: modeldata updated with
- modeldata["postprocessing"]["exported_files"] = array of  names of exported
  files
- modeldata["postprocessing"]["exported_fields"] = array of exported fields
"""
function exportdeformation(modeldata::FDataDict)
  modeldata_recognized_keys = ["fens", "regions", "geom", "u", "postprocessing"]
  postprocessing_recognized_keys = ["boundary_only", "file"]
  # Defaults
  boundary_only = false;
  ffile = "deformation"
  dcheck!(modeldata, modeldata_recognized_keys)

  # Let's have a look at what's been specified
  postprocessing = get(modeldata, "postprocessing", nothing);
  if (postprocessing != nothing)
    dcheck!(postprocessing, postprocessing_recognized_keys)
    boundary_only =  get(postprocessing, "boundary_only", boundary_only);
    ffile =  get(postprocessing, "file", ffile);
  end

  fens = get(()->error("Must get fens!"), modeldata, "fens")
  geom = get(()->error("Must get geometry field!"), modeldata, "geom");
  u = get(()->error("Must get displacement field!"), modeldata, "u");

  # Export one file for each region
  modeldata["postprocessing"]["exported_files"] = Array{String, 1}()
  modeldata["postprocessing"]["exported_fields"] = Array{Field, 1}()
  regions = get(()->error("Must get region!"), modeldata, "regions")
  for i = 1:length(regions)
    region = regions[i]
    femm = region["femm"]
    rfile = ffile * "$i" * ".vtk";
    if boundary_only
      bfes = meshboundary(femm.geod.fes);
      vtkexportmesh(rfile, fens, bfes;  vectors=[("u", u.values)])
    else
      vtkexportmesh(rfile, fens, femm.geod.fes; vectors=[("u", u.values)])
    end
    push!(modeldata["postprocessing"]["exported_files"], rfile)
    push!(modeldata["postprocessing"]["exported_fields"], u)
  end

  return modeldata
end

"""
    AlgoDeforLinearModule.exportstress(modeldata::FDataDict)

Algorithm for exporting of the stress for visualization in Paraview.

`modeldata` = dictionary with values for keys

- "fens"  = finite element node set
- "regions"  = array of region dictionaries
- "geom" = geometry field
- "u" = displacement field
- "postprocessing" = dictionary  with values for keys
  + "boundary_only" = should only the boundary of the  regions be rendered?
                      Default is render the interior.
  + "file" = name of the  postprocessing file
  + "quantity" = quantity to be exported (default :Cauchy)
  + "component" = which component of the quantity?
  + "outputcsys" = output coordinate system

For each region (connected piece of the domain made of a particular material),
mandatory, the  region dictionary  contains values for keys:
- "femm" = finite element mmodel machine (mandatory);

Output: modeldata updated with
- modeldata["postprocessing"]["exported_files"] = array of  names of exported
  files
- modeldata["postprocessing"]["exported_fields"] = array of exported fields
"""
function exportstress(modeldata::FDataDict)
  modeldata_recognized_keys = ["fens", "regions", "geom", "u",
            "dT", "postprocessing"]
  postprocessing_recognized_keys = ["boundary_only", "file", "quantity",
            "component", "outputcsys" ]
  # Defaults
  boundary_only = false;
  ffile = "stress"
  dcheck!(modeldata, modeldata_recognized_keys)
  quantity = :Cauchy
  component = 1
  outputcsys = nothing
  # Let's have a look at what's been specified
  postprocessing = get(modeldata, "postprocessing", nothing);
  if (postprocessing != nothing)
    dcheck!(postprocessing, postprocessing_recognized_keys)
    boundary_only = get(postprocessing, "boundary_only", boundary_only);
    ffile = get(postprocessing, "file", ffile);
    quantity = get(postprocessing, "quantity", quantity);
    component = get(postprocessing, "component", component);
    outputcsys = get(postprocessing, "outputcsys", outputcsys);
  end

  fens = get(()->error("Must get fens!"), modeldata, "fens")
  geom = get(()->error("Must get geometry field!"), modeldata, "geom");
  u = get(()->error("Must get displacement field!"), modeldata, "u");
  dT = get(modeldata, "dT", nothing);

  context = []
  if (outputcsys != nothing)
    push!(context, (:outputcsys, outputcsys))
  end

  # Export a file for each region
  modeldata["postprocessing"]["exported_files"] = Array{String, 1}()
  modeldata["postprocessing"]["exported_fields"] = Array{Field, 1}()
  regions = get(()->error("Must get region!"), modeldata, "regions")
  for i = 1:length(regions)
    region = regions[i]
    femm = region["femm"]
    rfile = ffile * "-" * string(quantity) * string(component) * "-region $i" * ".vtk";
    if (typeof(component) == Symbol)
      componentnum = stresscomponentmap(femm.mr)[component]
    else
      componentnum = component
    end
    # Note that we are creating a field  separately for each region.  This is
    # important  for the following reason: if the regions were of different
    # materials, or if they were of the same material but with different material
    # axes orientation, averaging across the material interface  would not make
    # sense.
    if (dT != nothing)
      fld = fieldfromintegpoints(femm, geom, u, dT, quantity, componentnum;
           context...)
    else
      fld = fieldfromintegpoints(femm, geom, u, quantity, componentnum;
        context...)
    end
    if boundary_only
      bfes = meshboundary(femm.geod.fes);
      vtkexportmesh(rfile, fens, bfes;
        scalars=[(string(quantity)*string(component), fld.values)],
        vectors=[("u", u.values)])
    else
      vtkexportmesh(rfile, fens, femm.geod.fes;
        scalars=[(string(quantity)*string(component), fld.values)],
        vectors=[("u", u.values)])
    end
    push!(modeldata["postprocessing"]["exported_files"], rfile)
    push!(modeldata["postprocessing"]["exported_fields"], fld)
  end

  return modeldata
end

"""
    AlgoDeforLinearModule.exportstresselementwise(modeldata::FDataDict)


Algorithm for exporting of the elementwise stress for visualization in Paraview.

`modeldata` = dictionary with values for keys

- "fens"  = finite element node set
- "regions"  = array of region dictionaries
- "geom" = geometry field
- "u" = displacement field
- "postprocessing" = dictionary  with values for keys
  + "boundary_only" = should only the boundary of the  regions be rendered?
                      Default is render the interior.
  + "file" = name of the  postprocessing file
  + "quantity" = quantity to be exported (default :Cauchy)
  + "component" = which component of the quantity?
  + "outputcsys" = output coordinate system

For each region (connected piece of the domain made of a particular material),
mandatory, the  region dictionary  contains values for keys:
- "femm" = finite element mmodel machine (mandatory);

Output: modeldata updated with
- modeldata["postprocessing"]["exported_files"] = array of  names of exported
  files
- modeldata["postprocessing"]["exported_fields"] = array of exported fields
"""
function exportstresselementwise(modeldata::FDataDict)
  modeldata_recognized_keys = ["fens", "regions", "geom", "u",
            "dT", "postprocessing"]
  postprocessing_recognized_keys = ["boundary_only", "file", "quantity",
            "component", "outputcsys" ]
  # Defaults
  boundary_only = false;
  ffile = "stress"
  dcheck!(modeldata, modeldata_recognized_keys)
  quantity = :Cauchy
  component = 1
  outputcsys = nothing
  # Let's have a look at what's been specified
  postprocessing = get(modeldata, "postprocessing", nothing);
  if (postprocessing != nothing)
    dcheck!(postprocessing, postprocessing_recognized_keys)
    boundary_only = get(postprocessing, "boundary_only", boundary_only);
    ffile = get(postprocessing, "file", ffile);
    quantity = get(postprocessing, "quantity", quantity);
    component = get(postprocessing, "component", component);
    outputcsys = get(postprocessing, "outputcsys", outputcsys);
  end

  fens = get(()->error("Must get fens!"), modeldata, "fens")
  geom = get(()->error("Must get geometry field!"), modeldata, "geom");
  u = get(()->error("Must get displacement field!"), modeldata, "u");
  dT = get(modeldata, "dT", nothing);

  context = []
  if (outputcsys != nothing)
    push!(context, (:outputcsys, outputcsys))
  end

  # Export a file for each region
  modeldata["postprocessing"]["exported_files"] = Array{String, 1}()
  modeldata["postprocessing"]["exported_fields"] = Array{Field, 1}()
  regions = get(()->error("Must get region!"), modeldata, "regions")
  for i = 1:length(regions)
    region = regions[i]
    femm = region["femm"]
    rfile = ffile * "-" * string(quantity) * string(component) * "-region $i" * ".vtk";
    if (typeof(component) == Symbol)
      componentnum = stresscomponentmap(femm.mr)[component]
    else
      componentnum = component
    end
    # Note that we are creating a field  separately for each region.  This is
    # important  for the following reason: if the regions were of different
    # materials, or if they were of the same material but with different material
    # axes orientation, averaging across the material interface  would not make
    # sense.
    if (dT != nothing)
      fld = elemfieldfromintegpoints(femm, geom, u, dT, quantity, componentnum;
           context...)
    else
      fld = elemfieldfromintegpoints(femm, geom, u, quantity, componentnum;
        context...)
    end
    if boundary_only
      bfes = meshboundary(femm.geod.fes);
      vtkexportmesh(rfile, fens, bfes;
        scalars=[(string(quantity)*string(component), fld.values)],
        vectors=[("u", u.values)])
    else
      vtkexportmesh(rfile, fens, femm.geod.fes;
        scalars=[(string(quantity)*string(component), fld.values)],
        vectors=[("u", u.values)])
    end
    push!(modeldata["postprocessing"]["exported_files"], rfile)
    push!(modeldata["postprocessing"]["exported_fields"], u)
  end

  return modeldata
end

"""
    AlgoDeforLinearModule.modal(modeldata::FDataDict)

Modal (free-vibration) analysis solver.


`modeldata` = dictionary with values for keys

- "fens"  = finite element node set
- "regions"  = array of region dictionaries
- "essential_bcs" = array of essential boundary condition dictionaries

For each region (connected piece of the domain made of a particular material),
mandatory, the  region dictionary  contains values for keys:
- "femm" = finite element mmodel machine (mandatory);

For essential boundary conditions (optional) each dictionary
would hold
  + "displacement" = fixed (prescribed) displacement (scalar),  or
            a function with signature
                function w = f(x)
            If not given, zero displacement assumed.
  + "component" = which component is prescribed  (1, 2, 3)?
  + "node_list" = list of nodes on the boundary to which the condition applies
            (mandatory)

Control parameters:
- "neigvs" = number of eigenvalues/eigenvectors to compute
- "omega_shift"= angular frequency shift for mass shifting
- "use_lumped_mass" = true or false?  (Default is false: consistent mass)


Output:
modeldata= the dictionary on input is augmented with
- "geom" = the nodal field that is the geometry
- "u" = the nodal field that is the computed displacement
- "neigvs" = Number of computed eigenvectors
- "W" = Computed eigenvectors, neigvs columns
- "omega" =  Computed angular frequencies, array of length neigvs
- "raw_eigenvalues" = Raw computed eigenvalues
"""
function modal(modeldata::FDataDict)

  # For multi point constraints (MPC) (optional):
  # model_data.mpc= cell array of structs, each for one MPC.
  #      mpc.node_list = list of node numbers involved in the MPC,
  #      mpc.dof_list= numbers of degrees of freedom for the nodes above,
  #      mpc.umultipliers=multipliers for the nodes above,
  #      mpc.penfact=the penalty factor to multiply  the constraint matrix,
  #          The MPC looks like this: sum_i m_i u_{dof(i),node(i)} =0
  #          where m_i is the multiplier.


  # Lists of recognized keys for the data dictionaries:
  modeldata_recognized_keys = ["fens", "regions",
  "essential_bcs", "neigvs", "omega_shift", "use_lumped_mass"]
  essential_bcs_recognized_keys = ["displacement", "node_list", "component"]
  regions_recognized_keys = ["femm", "femm_stiffness", "femm_mass", "body_load"]

  neigvs = get(modeldata, "neigvs", 7); # Number of eigenvalues

  omega_shift = get(modeldata, "omega_shift", 0.0); # Mass shifting

  use_factorization = get(modeldata, "use_factorization", false); # Factorization?

  use_lumped_mass = get(modeldata, "use_lumped_mass", false); # Lumped mass?

  # Extract the nodes
  fens = get(()->error("Must get fens!"), modeldata, "fens")

  # Construct the geometry field
  geom = NodalField(fens.xyz)

  # Construct the displacement field
  u = NodalField(zeros(nnodes(geom),ndofs(geom)))

  # Apply the essential boundary conditions on the displacement field
  essential_bcs = get(modeldata, "essential_bcs", nothing);
  if (essential_bcs != nothing)
    for j = 1:length(essential_bcs)
      ebc = essential_bcs[j]
      dcheck!(ebc, essential_bcs_recognized_keys)
      fenids = get(()->error("Must get node list!"), ebc, "node_list");
      displacement = get(ebc, "displacement", nothing);
      u_fixed = zeros(FFlt, length(fenids)); # default is  zero displacement
      if (displacement != nothing) # if it is nonzero,
        if (typeof(displacement) <: Function) # it could be a function
          for k = 1:length(fenids)
            u_fixed[k] = displacement(geom.values[fenids[k],:])[1];
          end
        else # or it could be a constant
          fill!(u_fixed, displacement);
        end
      end
      component = get(ebc, "component", 0); # which component?
      setebc!(u, fenids[:], true, component, u_fixed);
    end
    applyebc!(u);
  end

  # Number the equations
  numberdofs!(u)           #,Renumbering_options); # NOT DONE <<<<<<<<<<<<<<<<<

  # Construct the system stiffness matrix
  K = spzeros(u.nfreedofs,u.nfreedofs); # (all zeros, for the moment)
  regions = get(()->error("Must get region list!"), modeldata, "regions")
  for i = 1:length(regions)
    region = regions[i]
    dcheck!(region, regions_recognized_keys)
    if "femm_stiffness"  in keys(region)
      femm = region["femm_stiffness"];
    else
      femm = get(()->error("Must get femm or femm_stiffness!"), region, "femm")
    end
    # # Give the  FEMM a chance  to precompute  geometry-related quantities
    # region.femm = associate_geometry(region.femm,geom);
    # Add up all the stiffness matrices for all the regions
    K = K + stiffness(femm, geom, u);
  end

  # Construct the system mass matrix
  M = spzeros(u.nfreedofs,u.nfreedofs); # (all zeros, for the moment)
  regions = get(()->error("Must get region list!"), modeldata, "regions")
  for i = 1:length(regions)
    region = regions[i]
    dcheck!(region, regions_recognized_keys)
    if "femm_mass"  in keys(region)
      femm = region["femm_mass"];
    else
      femm = get(()->error("Must get femm or femm_mass!"), region, "femm")
    end
    # # Give the  FEMM a chance  to precompute  geometry-related quantities
    # region.femm = associate_geometry(region.femm,geom);
    # Add up all the mass matrices for all the regions
    M = M + mass(femm, geom, u);
  end

  # Options for the eigenproblem solution

  # Solve
  # if (~ use_factorization )
  #     # This is one way of solving the eigenvalue problem, just pass the matrices
  #     [W,Omega]= eigs(K+omega_shift*M, M, neigvs, 'SM', evopts);
  # else
  # This form uses the factorized matrix and has the potential of being much faster
  # Factorize the left-hand side matrix for efficiency (Choleski)
  # [mA,status] = chol(K+omega_shift*M,'lower');#,'vector',prm
  # if ( status ~= 0 ) error('Choleski factorization failed'), end
  # clear K; # Not needed anymore
  # mAt= mA';
  # [W,Omega]= eigs(@(bv)mAt\(mA\bv), u.nfreedofs, M, neigvs, 'SM', evopts);
  #          [W,Omega]= eig(full(K+omega_shift*M), full(M));

  d,v,nev,nconv = eigs(K+omega_shift*M, M; nev=neigvs, which=:SM)
  d = d - omega_shift;

  modeldata["raw_eigenvalues"] = d;
  #    Subtract the mass-shifting Angular frequency
  if any(imag(d) .!= 0.0)
    d=real(d);
  end
  if any(real(d) .< 0.0)
    d = abs.(d);
  end
  #    Sort  the angular frequencies by magnitude.  Make sure all
  #    imaginary parts of the eigenvalues are removed.
  ix =sortperm(d);

  # Update the model data: store geometry
  modeldata["geom"] = geom;
  # Store the displacement field
  modeldata["u"] = u;
  # Number of computed eigenvectors
  modeldata["neigvs"] = nev;
  #  Computed eigenvectors: we are ignoring the imaginary part here
  #  because the modal analysis is presumed to have been performed for
  #  an undamped structure
  modeldata["W"] = real(v[:,ix]);
  #  Computed angular frequencies
  modeldata["omega"] = sqrt.(d[ix]);
  return modeldata
end

"""
    AlgoDeforLinearModule.exportmode(modeldata::FDataDict)

Algorithm for exporting of the mmode shape for visualization in Paraview.

`modeldata` = dictionary with values for keys

- "fens"  = finite element node set
- "regions"  = array of region dictionaries
- "geom" = geometry field
- "u" = displacement field
- "W" = Computed free-vibration eigenvectors, neigvs columns
- "omega" =  Computed free-vibration angular frequencies, array of length neigvs
- "postprocessing" = dictionary  with values for keys
  + "boundary_only" = should only the boundary of the  regions be rendered?
                      Default is render the interior.
  + "file" = name of the  postprocessing file
  + "mode" = which mode should be visualized?
  + "component" = which component of the quantity?
  + "outputcsys" = output coordinate system

For each region (connected piece of the domain made of a particular material),
mandatory, the  region dictionary  contains values for keys:
- "femm" = finite element mmodel machine (mandatory);

Output: modeldata updated with
- modeldata["postprocessing"]["exported_files"] = array of  names of exported
  files
- modeldata["postprocessing"]["exported_fields"] = array of exported fields
"""
function exportmode(modeldata::FDataDict)
  modeldata_recognized_keys = ["fens", "regions", "geom", "u",
    "omega", "W",
    "postprocessing"]
  postprocessing_recognized_keys = ["boundary_only", "file", "mode"]
  mode = 1;
  dcheck!(modeldata, modeldata_recognized_keys)

  # Let's have a look at what's been specified
  postprocessing = get(modeldata, "postprocessing", nothing);
  if (postprocessing != nothing)
    dcheck!(postprocessing, postprocessing_recognized_keys)
    mode =  get(postprocessing, "mode", mode);
  end

  omega=modeldata["omega"]
  if (length(omega)<mode) || (mode<0)
    error("Invalid node number $mode")
  end

  # Scatter the desired mode
  W = modeldata["W"]
  scattersysvec!(modeldata["u"], W[:,mode])

  return exportdeformation(modeldata)
end

end
